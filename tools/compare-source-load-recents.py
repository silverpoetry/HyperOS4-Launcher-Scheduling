import argparse
import os
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

PERFETTO_SITE = os.environ.get("PERFETTO_PYTHON")
if PERFETTO_SITE:
    sys.path.insert(0, PERFETTO_SITE)

from perfetto.trace_processor import TraceProcessor


def rows(tp, sql):
    result = tp.query(sql)
    names = result.column_names
    return [{name: getattr(row, name) for name in names} for row in result]


def phases(path):
    result = {}
    for line in path.read_text(encoding="ascii").splitlines():
        match = re.match(r"phase=(\S+) uptime=([0-9.]+)", line)
        if match:
            result[match.group(1)] = int(float(match.group(2)) * 1_000_000_000)
    return result


def percentile(values, fraction):
    if not values:
        return 0.0
    values = sorted(values)
    return values[min(len(values) - 1, round((len(values) - 1) * fraction))]


def intervals(phase):
    entry = []
    returning = []
    for number in range(1, 5):
        before = phase[f"round_{number}_before_gesture"]
        after_gesture = phase[f"round_{number}_after_gesture"]
        after_tap = phase[f"round_{number}_after_tap"]
        entry.append((before, after_gesture + 800_000_000))
        returning.append((after_tap, after_tap + 800_000_000))
    return {"entry": entry, "return": returning}


def condition(alias, windows):
    return "(" + " or ".join(
        f"({alias}.ts < {end} and {alias}.ts+{alias}.dur > {start})"
        for start, end in windows
    ) + ")"


def point_condition(alias, windows):
    return "(" + " or ".join(
        f"({alias}.ts >= {start} and {alias}.ts < {end})"
        for start, end in windows
    ) + ")"


def overlap_expression(alias, windows):
    terms = [
        f"max(0,min({alias}.ts+{alias}.dur,{end})-max({alias}.ts,{start}))"
        for start, end in windows
    ]
    return "(" + "+".join(terms) + ")"


def summarize_case(case_dir, source_process):
    phase = phases(case_dir / "phases.txt")
    groups = intervals(phase)
    tp = TraceProcessor(trace=str(case_dir / "trace.perfetto-trace"))
    output = {}
    try:
        output["gpu_tracks"] = rows(tp, """
          select id,name,type from counter_track
          where lower(name) like '%gpu%' or lower(name) like '%freq%'
          order by name
        """)
        for group_name, windows in groups.items():
            duration_ms = sum(end - start for start, end in windows) / 1e6
            sched_cond = condition("s", windows)
            sched_overlap = overlap_expression("s", windows)
            state_cond = condition("st", windows)
            state_overlap = overlap_expression("st", windows)
            slice_cond = condition("sl", windows)
            frame_cond = point_condition("f", windows)

            processes = rows(tp, f"""
              select p.name process,round(sum({sched_overlap})/1e6,3) run_ms
              from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
              where {sched_cond} and
                (p.name in ('com.miui.home','system_server','com.android.systemui',
                            '/system/bin/surfaceflinger','{source_process}')
                 or (p.name like '{source_process}:%'))
              group by p.name order by run_ms desc
            """)
            source_cpu = rows(tp, f"""
              select s.cpu,round(sum({sched_overlap})/1e6,3) run_ms
              from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
              where {sched_cond} and (p.name='{source_process}' or p.name like '{source_process}:%')
              group by s.cpu order by s.cpu
            """)
            total_cpu = rows(tp, f"""
              select s.cpu,round(sum({sched_overlap})/1e6,3) run_ms
              from sched s join thread t on s.utid=t.utid
              where {sched_cond} and t.is_idle=0 group by s.cpu order by s.cpu
            """)
            system_threads = rows(tp, f"""
              select t.name thread,round(sum({sched_overlap})/1e6,3) run_ms
              from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
              where {sched_cond} and p.name='system_server'
              group by t.name order by run_ms desc
            """)
            source_threads = rows(tp, f"""
              select t.name thread,round(sum({sched_overlap})/1e6,3) run_ms
              from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
              where {sched_cond} and (p.name='{source_process}' or p.name like '{source_process}:%')
              group by t.name order by run_ms desc
            """)
            key_threads = rows(tp, f"""
              select p.name process,t.name thread,st.state,
                     round(sum({state_overlap})/1e6,3) state_ms
              from thread_state st join thread t on st.utid=t.utid join process p on t.upid=p.upid
              where {state_cond} and
                ((p.name='com.miui.home' and t.name in ('1.ui','1.raster','com.miui.home'))
                 or (p.name='system_server' and t.name in ('TaskSnapshotPer','android.anim','android.display'))
                 or (p.name='/system/bin/surfaceflinger' and t.tid=p.pid))
              group by p.upid,t.utid,st.state order by p.name,t.name,st.state
            """)
            launcher_draws = rows(tp, f"""
              select sl.dur from slice sl join thread_track tt on sl.track_id=tt.id
              join thread t on tt.utid=t.utid join process p on t.upid=p.upid
              where {slice_cond} and p.name='com.miui.home' and t.name='1.raster'
                and sl.name like 'GPURasterizer::Draw%'
            """)
            launcher_encodes = rows(tp, f"""
              select sl.dur,sl.name from slice sl join thread_track tt on sl.track_id=tt.id
              join thread t on tt.utid=t.utid join process p on t.upid=p.upid
              where {slice_cond} and p.name='com.miui.home' and t.name='1.raster'
                and sl.name in ('SurfaceFrame::Encode V:0','SurfaceFrame::Encode V:1')
            """)
            source_work = rows(tp, f"""
              select case
                       when sl.name like 'waiting for GPU completion%' then 'waiting for GPU completion'
                       when sl.name like 'GPURasterizer::Draw%' then 'GPURasterizer::Draw'
                       when sl.name like 'DrawFrame%' then 'DrawFrames'
                       else sl.name
                     end name,
                     count(*) count,round(sum({overlap_expression('sl', windows)})/1e6,3) wall_ms,
                     round(max(sl.dur)/1e6,3) max_ms
              from slice sl join thread_track tt on sl.track_id=tt.id
              join thread t on tt.utid=t.utid join process p on t.upid=p.upid
              where {slice_cond} and (p.name='{source_process}' or p.name like '{source_process}:%')
                and (sl.name='eglSwapBuffers' or sl.name='queueBuffer'
                     or sl.name like 'GPURasterizer::Draw%'
                     or sl.name like 'DrawFrame%'
                     or sl.name like 'waiting for GPU completion%')
              group by 1 order by wall_ms desc
            """)
            frames = rows(tp, f"""
              select coalesce(p.name,'SurfaceFlinger') process,f.jank_severity_type,
                     f.jank_type,f.gpu_composition,count(*) count
              from actual_frame_timeline_slice f left join process p on f.upid=p.upid
              where {frame_cond} and
                (p.name in ('com.miui.home','com.android.systemui','{source_process}',
                            '/system/bin/surfaceflinger')
                 or p.name like '{source_process}:%')
              group by process,f.jank_severity_type,f.jank_type,f.gpu_composition
              order by process,count desc
            """)
            source_frame_count = rows(tp, f"""
              select count(*) count,
                     sum(case when f.present_type='Dropped Frame' then 1 else 0 end) dropped
              from actual_frame_timeline_slice f join process p on f.upid=p.upid
              where {frame_cond} and f.surface_frame_token is not null
                and (p.name='{source_process}' or p.name like '{source_process}:%')
            """)[0]

            draw_values = [value["dur"] / 1e6 for value in launcher_draws]
            encode0 = [value["dur"] / 1e6 for value in launcher_encodes if value["name"].endswith("V:0")]
            encode1 = [value["dur"] / 1e6 for value in launcher_encodes if value["name"].endswith("V:1")]
            output[group_name] = {
                "window_ms": duration_ms,
                "process_runtime": processes,
                "source_cpu": source_cpu,
                "total_cpu": total_cpu,
                "system_threads": system_threads,
                "source_threads": source_threads,
                "key_thread_states": key_threads,
                "launcher_draw": {
                    "count": len(draw_values),
                    "over_8_33": sum(value > 8.33 for value in draw_values),
                    "p50_ms": round(statistics.median(draw_values), 3) if draw_values else 0,
                    "p95_ms": round(percentile(draw_values, .95), 3),
                    "max_ms": round(max(draw_values), 3) if draw_values else 0,
                    "encode0_p95_ms": round(percentile(encode0, .95), 3),
                    "encode0_max_ms": round(max(encode0), 3) if encode0 else 0,
                    "encode1_p95_ms": round(percentile(encode1, .95), 3),
                },
                "source_work": source_work,
                "source_frames": source_frame_count,
                "frames": frames,
            }
    finally:
        tp.close()
    return output


def keyed_runtime(values):
    return {value["process"]: value["run_ms"] for value in values}


def keyed_states(values):
    result = defaultdict(lambda: defaultdict(float))
    for value in values:
        result[(value["process"], value["thread"])][value["state"]] += value["state_ms"]
    return result


def keyed_threads(values):
    return {value["thread"]: value["run_ms"] for value in values}


def print_comparison(high, low, group):
    print(f"\n# {group}")
    high_group = high[group]
    low_group = low[group]
    print("launcher_draw high", high_group["launcher_draw"])
    print("launcher_draw low ", low_group["launcher_draw"])
    high_runtime = keyed_runtime(high_group["process_runtime"])
    low_runtime = keyed_runtime(low_group["process_runtime"])
    print("process runtime delta high-low ms")
    for process in sorted(set(high_runtime) | set(low_runtime)):
        print(f"  {process}: high={high_runtime.get(process,0):.3f} "
              f"low={low_runtime.get(process,0):.3f} "
              f"delta={high_runtime.get(process,0)-low_runtime.get(process,0):+.3f}")
    print("source cpu high", high_group["source_cpu"])
    print("source cpu low ", low_group["source_cpu"])
    print("total cpu high", high_group["total_cpu"])
    print("total cpu low ", low_group["total_cpu"])
    high_system = keyed_threads(high_group["system_threads"])
    low_system = keyed_threads(low_group["system_threads"])
    system_deltas = sorted(
        ((high_system.get(thread, 0) - low_system.get(thread, 0), thread,
          high_system.get(thread, 0), low_system.get(thread, 0))
         for thread in set(high_system) | set(low_system)),
        reverse=True,
    )
    print("system_server top positive runtime deltas high-low ms")
    for delta, thread, high_ms, low_ms in system_deltas[:20]:
        print(f"  {thread}: high={high_ms:.3f} low={low_ms:.3f} delta={delta:+.3f}")
    print("source top threads high", high_group["source_threads"][:20])
    print("source top threads low ", low_group["source_threads"][:20])
    print("source work high", high_group["source_work"])
    print("source work low ", low_group["source_work"])
    print("source frames high", high_group["source_frames"])
    print("source frames low ", low_group["source_frames"])
    high_states = keyed_states(high_group["key_thread_states"])
    low_states = keyed_states(low_group["key_thread_states"])
    print("key thread Running/Runnable high vs low")
    for key in sorted(set(high_states) | set(low_states)):
        hs = high_states[key]
        ls = low_states[key]
        high_runq = hs.get("R", 0) + hs.get("R+", 0)
        low_runq = ls.get("R", 0) + ls.get("R+", 0)
        print(f"  {key}: running {hs.get('Running',0):.3f}/{ls.get('Running',0):.3f} "
              f"runnable {high_runq:.3f}/{low_runq:.3f}")
    print("Full/Partial jank high")
    for value in high_group["frames"]:
        if value["jank_severity_type"] in ("Full", "Partial"):
            print(" ", value)
    print("Full/Partial jank low")
    for value in low_group["frames"]:
        if value["jank_severity_type"] in ("Full", "Partial"):
            print(" ", value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pair_dir", type=Path)
    parser.add_argument("--high-dir", default="high-jkchess")
    parser.add_argument("--low-dir", default="low-settings")
    parser.add_argument("--high-process", default="com.tencent.jkchess")
    parser.add_argument("--low-process", default="com.android.settings")
    args = parser.parse_args()
    high = summarize_case(args.pair_dir / args.high_dir, args.high_process)
    low = summarize_case(args.pair_dir / args.low_dir, args.low_process)
    print("gpu tracks high", high["gpu_tracks"])
    print("gpu tracks low ", low["gpu_tracks"])
    print_comparison(high, low, "entry")
    print_comparison(high, low, "return")


if __name__ == "__main__":
    main()

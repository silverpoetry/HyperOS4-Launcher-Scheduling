import argparse
import json
import os
import re
import statistics
import sys
from pathlib import Path


perfetto_site = os.environ.get("PERFETTO_PYTHON")
if perfetto_site:
    sys.path.insert(0, perfetto_site)

from perfetto.trace_processor import TraceProcessor


def rows(tp, sql):
    result = tp.query(sql)
    names = result.column_names
    return [{name: getattr(row, name) for name in names} for row in result]


def parse_phases(path):
    result = {}
    pattern = re.compile(r"phase=(\S+) uptime=([0-9.]+)")
    for line in path.read_text(encoding="ascii").splitlines():
        match = pattern.match(line)
        if match:
            result[match.group(1)] = int(float(match.group(2)) * 1_000_000_000)
    return result


def overlap(alias, start, end):
    return f"max(0,min({alias}.ts+{alias}.dur,{end})-max({alias}.ts,{start}))"


def window_condition(alias, windows):
    return "(" + " or ".join(
        f"({alias}.ts < {end} and {alias}.ts+{alias}.dur > {start})"
        for start, end in windows
    ) + ")"


def point_condition(alias, windows):
    return "(" + " or ".join(
        f"({alias}.ts >= {start} and {alias}.ts < {end})"
        for start, end in windows
    ) + ")"


def summed_overlap(alias, windows):
    return "(" + "+".join(overlap(alias, start, end) for start, end in windows) + ")"


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round((len(ordered) - 1) * fraction))]


def parse_stat(path):
    values = {}
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for index, line in enumerate(lines):
        if not line.startswith("NAME=") or index + 1 >= len(lines):
            continue
        name_match = re.search(r"NAME=(\S+)", line)
        pid_match = re.search(r"PID=(\d+)", line)
        fields = lines[index + 1].split()
        if name_match and pid_match and len(fields) >= 15:
            values[name_match.group(1)] = {
                "pid": int(pid_match.group(1)),
                "utime": int(fields[13]),
                "stime": int(fields[14]),
            }
    return values


def analyze_case(case_dir):
    phase = parse_phases(case_dir / "phases.txt")
    game_pid = int((case_dir / "game-pid.txt").read_text(encoding="ascii").strip())
    entry = []
    entry_steady = []
    returning = []
    for number in range(1, 5):
        before = phase[f"round_{number}_before_overview"]
        after_command = phase[f"round_{number}_after_overview_command"]
        before_tap = phase[f"round_{number}_before_card_tap"]
        after_tap = phase[f"round_{number}_after_card_tap"]
        next_start = phase.get(f"round_{number + 1}_before_overview", phase["stress_complete"])
        entry.append((before, before_tap))
        entry_steady.append((after_command + 100_000_000, before_tap))
        returning.append((after_tap, min(after_tap + 900_000_000, next_start)))

    tp = TraceProcessor(trace=str(case_dir / "trace.perfetto-trace"))
    report = {"case": case_dir.name, "game_pid": game_pid}
    try:
        report["trace_bounds"] = rows(
            tp, "select start_ts,end_ts,round((end_ts-start_ts)/1e6,3) duration_ms from trace_bounds"
        )[0]
        report["cgroup_arg_keys"] = rows(tp, """
          select distinct a.key from raw r join args a using(arg_set_id)
          where r.name='cgroup_attach_task' order by a.key
        """)
        report["cgroup_samples"] = rows(tp, """
          select r.ts,r.cpu,t.tid,t.name,a.key,a.display_value
          from raw r left join thread t on r.utid=t.utid
          join args a using(arg_set_id)
          where r.name='cgroup_attach_task'
          order by r.ts,a.key limit 80
        """)

        for label, windows in (("entry", entry), ("entry_steady", entry_steady), ("return", returning)):
            sched_condition = window_condition("s", windows)
            sched_overlap = summed_overlap("s", windows)
            state_condition = window_condition("st", windows)
            state_overlap = summed_overlap("st", windows)
            frame_condition = point_condition("f", windows)
            duration_ms = sum(end - start for start, end in windows) / 1e6

            item = {"window_ms": round(duration_ms, 3)}
            item["runtime"] = rows(tp, f"""
              select p.name process,round(sum({sched_overlap})/1e6,3) run_ms
              from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
              where {sched_condition} and
                (p.name in ('com.miui.home','com.android.systemui','system_server',
                            '/system/bin/surfaceflinger')
                 or p.name like 'com.tencent.jkchess%'
                 or p.name like '%launcher-logwat%'
                 or p.name like '%source-guard%')
              group by p.upid order by run_ms desc
            """)
            item["daemon_threads"] = rows(tp, f"""
              select p.name process,t.tid,t.name thread,
                     round(sum({sched_overlap})/1e6,3) run_ms
              from sched s join thread t using(utid) join process p using(upid)
              where {sched_condition} and
                (p.name like '%launcher-logwatch' or p.name like '%source-guard')
              group by p.upid,t.utid order by run_ms desc
            """)
            item["game_cpu"] = rows(tp, f"""
              select s.cpu,round(sum({sched_overlap})/1e6,3) run_ms
              from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
              where {sched_condition} and p.pid={game_pid}
              group by s.cpu order by s.cpu
            """)
            item["game_family_cpu"] = rows(tp, f"""
              select p.name process,s.cpu,round(sum({sched_overlap})/1e6,3) run_ms
              from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
              where {sched_condition} and p.name like 'com.tencent.jkchess%'
              group by p.upid,s.cpu order by run_ms desc
            """)
            item["game_priorities"] = rows(tp, f"""
              select s.priority,count(distinct t.utid) threads,
                     round(sum({sched_overlap})/1e6,3) run_ms
              from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
              where {sched_condition} and p.pid={game_pid}
              group by s.priority order by run_ms desc
            """)
            item["key_runnable"] = rows(tp, f"""
              select p.name process,t.name thread,
                     round(sum({state_overlap})/1e6,3) runnable_ms,
                     round(max({state_overlap})/1e6,3) max_runnable_ms
              from thread_state st join thread t on st.utid=t.utid
              join process p on t.upid=p.upid
              where {state_condition} and st.state in ('R','R+') and
                ((p.name='com.miui.home' and (t.tid=p.pid or t.name in ('1.ui','1.raster')))
                 or p.name in ('com.android.systemui','system_server','/system/bin/surfaceflinger'))
              group by p.upid,t.utid order by runnable_ms desc limit 30
            """)
            item["frames"] = rows(tp, f"""
              select coalesce(p.name,'SurfaceFlinger') process,
                     f.jank_severity_type severity,f.jank_type,
                     f.present_type,count(*) count,
                     round(max(f.dur)/1e6,3) max_ms
              from actual_frame_timeline_slice f left join process p on f.upid=p.upid
              where {frame_condition} and
                (p.name in ('com.miui.home','com.android.systemui','/system/bin/surfaceflinger')
                 or f.upid is null)
              group by process,severity,f.jank_type,f.present_type
              order by process,count desc
            """)
            launcher_frames = rows(tp, f"""
              select f.dur from actual_frame_timeline_slice f join process p on f.upid=p.upid
              where {frame_condition} and p.name='com.miui.home'
                and f.surface_frame_token is not null
            """)
            frame_ms = [value["dur"] / 1e6 for value in launcher_frames]
            item["launcher_frame_time"] = {
                "count": len(frame_ms),
                "over_8_33": sum(value > 8.33 for value in frame_ms),
                "over_16_67": sum(value > 16.67 for value in frame_ms),
                "p50_ms": round(statistics.median(frame_ms), 3) if frame_ms else 0,
                "p95_ms": round(percentile(frame_ms, 0.95), 3),
                "max_ms": round(max(frame_ms), 3) if frame_ms else 0,
            }
            report[label] = item

        # Practical suppression latency: first main-game scheduling on CPU0-2
        # and last scheduling on CPU3-7 in the first 300 ms after each command.
        timing = []
        for number in range(1, 5):
            command = phase[f"round_{number}_after_overview_command"]
            end = command + 300_000_000
            first_little = rows(tp, f"""
              select min(s.ts) ts from sched s join thread t on s.utid=t.utid
              join process p on t.upid=p.upid
              where p.pid={game_pid} and s.cpu<=2 and s.ts>={command} and s.ts<{end}
            """)[0]["ts"]
            last_big = rows(tp, f"""
              select max(s.ts+s.dur) ts from sched s join thread t on s.utid=t.utid
              join process p on t.upid=p.upid
              where p.pid={game_pid} and s.cpu>=3 and s.ts>={command} and s.ts<{end}
            """)[0]["ts"]
            timing.append({
                "round": number,
                "first_little_after_command_ms": None if first_little is None else round((first_little-command)/1e6, 3),
                "last_big_after_command_ms": None if last_big is None else round((last_big-command)/1e6, 3),
            })
        report["suppression_timing"] = timing
    finally:
        tp.close()

    before_file = case_dir / "daemon-before.txt"
    after_file = case_dir / "daemon-after.txt"
    if before_file.exists() and after_file.exists():
        before = parse_stat(before_file)
        after = parse_stat(after_file)
        report["daemon_ticks"] = {
            name: after[name]["utime"] + after[name]["stime"] - values["utime"] - values["stime"]
            for name, values in before.items() if name in after and before[name]["pid"] == after[name]["pid"]
        }
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result_dir", type=Path)
    args = parser.parse_args()
    report = {
        name: analyze_case(args.result_dir / name)
        for name in ("enabled-a", "disabled", "enabled-b")
    }
    output = args.result_dir / "analysis.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()

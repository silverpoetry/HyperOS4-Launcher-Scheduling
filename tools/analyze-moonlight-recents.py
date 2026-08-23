import argparse
import re
import sys
from pathlib import Path

PERFETTO_SITE = Path(r"D:\Projects\HyperOS4-Sheng-DSU\tools\perfetto-python")
if PERFETTO_SITE.exists():
    sys.path.insert(0, str(PERFETTO_SITE))

from perfetto.trace_processor import TraceProcessor


TARGET_PROCESS = """
  (p.name = 'com.miui.home'
   or p.name = 'com.silverpoetry.moonlight'
   or p.name = 'com.android.systemui'
   or p.name = 'system_server'
   or lower(p.name) like '%surfaceflinger%')
"""


def rows(tp, sql):
    result = tp.query(sql)
    columns = result.column_names
    return [{column: getattr(row, column) for column in columns} for row in result]


def phase_times(path):
    phases = {}
    for line in path.read_text(encoding="ascii").splitlines():
        match = re.match(r"phase=(\S+) uptime=([0-9.]+)", line)
        if match:
            phases[match.group(1)] = int(float(match.group(2)) * 1_000_000_000)
    required = {"before_recents", "after_recents_command", "before_card_tap", "after_card_tap", "complete"}
    missing = required - phases.keys()
    if missing:
        raise RuntimeError(f"missing phases in {path}: {sorted(missing)}")
    return phases


def sql_time_overlap(alias, start, end):
    return f"max(0, min({alias}.ts + {alias}.dur, {end}) - max({alias}.ts, {start}))"


def analyze_run(run_dir):
    trace = run_dir / "trace.perfetto-trace"
    phases = phase_times(run_dir / "phases.txt")
    windows = {
        "pre": (phases["before_recents"] - 500_000_000, phases["before_recents"]),
        "enter": (phases["before_recents"], phases["after_recents_command"] + 800_000_000),
        "recents": (phases["after_recents_command"] + 800_000_000, phases["before_card_tap"]),
        "return": (phases["before_card_tap"], phases["after_card_tap"] + 1_000_000_000),
        "post": (phases["after_card_tap"] + 1_000_000_000, phases["complete"]),
    }
    tp = TraceProcessor(trace=str(trace))
    output = {"run": run_dir.name, "phases": phases, "windows": {}}
    output["bounds"] = rows(tp, "select start_ts,end_ts,(end_ts-start_ts)/1e6 dur_ms from trace_bounds")[0]

    for phase, (start, end) in windows.items():
        overlap = sql_time_overlap("s", start, end)
        state_overlap = sql_time_overlap("st", start, end)
        frame_filter = f"f.ts < {end} and f.ts + f.dur > {start}"
        window = {"start": start, "end": end, "duration_ms": (end - start) / 1e6}
        window["process_runtime"] = rows(tp, f"""
          select p.name process, round(sum({overlap})/1e6,3) run_ms,
                 group_concat(distinct s.cpu) cpus
          from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
          where s.ts < {end} and s.ts+s.dur > {start} and {TARGET_PROCESS}
          group by p.name order by run_ms desc
        """)
        window["all_process_runtime"] = rows(tp, f"""
          select p.name process,round(sum({overlap})/1e6,3) run_ms
          from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
          where t.tid != 0 and s.ts < {end} and s.ts+s.dur > {start}
          group by p.upid order by run_ms desc limit 20
        """)
        window["moonlight_by_cpu"] = rows(tp, f"""
          select s.cpu,round(sum({overlap})/1e6,3) run_ms
          from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
          where s.ts < {end} and s.ts+s.dur > {start}
            and p.name='com.silverpoetry.moonlight'
          group by s.cpu order by s.cpu
        """)
        window["top_threads"] = rows(tp, f"""
          select p.name process,t.name thread,round(sum({overlap})/1e6,3) run_ms,
                 group_concat(distinct s.cpu) cpus
          from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
          where s.ts < {end} and s.ts+s.dur > {start} and {TARGET_PROCESS}
          group by p.name,t.utid order by run_ms desc limit 24
        """)
        window["runnable"] = rows(tp, f"""
          select p.name process,t.name thread,round(sum({state_overlap})/1e6,3) runnable_ms,
                 round(max(st.dur)/1e6,3) max_runnable_ms
          from thread_state st join thread t on st.utid=t.utid join process p on t.upid=p.upid
          where st.state='R' and st.ts < {end} and st.ts+st.dur > {start} and {TARGET_PROCESS}
          group by p.name,t.utid having runnable_ms >= 0.25
          order by runnable_ms desc limit 24
        """)
        window["jank"] = rows(tp, f"""
          select coalesce(p.name,'SurfaceFlinger') process,f.layer_name,f.present_type,
                 f.jank_type,f.jank_severity_type,f.gpu_composition,
                 round((f.ts-{start})/1e6,3) offset_ms,round(f.dur/1e6,3) dur_ms
          from actual_frame_timeline_slice f left join process p on f.upid=p.upid
          where {frame_filter} and f.jank_severity_type in ('Full','Partial')
          order by f.ts
        """)
        window["long_slices"] = rows(tp, f"""
          select p.name process,t.name thread,s.name,count(*) count,
                 round(sum(s.dur)/1e6,3) total_ms,round(max(s.dur)/1e6,3) max_ms
          from slice s join thread_track tt on s.track_id=tt.id
          join thread t on tt.utid=t.utid join process p on t.upid=p.upid
          where s.ts < {end} and s.ts+s.dur > {start} and s.dur>=2000000 and {TARGET_PROCESS}
          group by p.name,t.utid,s.name order by max_ms desc limit 30
        """)
        output["windows"][phase] = window

    enter_start = windows["enter"][0]
    return_end = windows["return"][1]
    sched_rows = rows(tp, f"""
      select s.ts,s.dur,s.cpu from sched s join thread t on s.utid=t.utid
      where t.tid != 0 and s.ts < {return_end} and s.ts+s.dur > {enter_start}
      order by s.ts
    """)
    bin_size = 20_000_000
    busy = {}
    for row in sched_rows:
        slice_start = max(int(row["ts"]), enter_start)
        slice_end = min(int(row["ts"]) + int(row["dur"]), return_end)
        if slice_end <= slice_start:
            continue
        first_bin = (slice_start - enter_start) // bin_size
        last_bin = (slice_end - 1 - enter_start) // bin_size
        for bin_index in range(first_bin, last_bin + 1):
            bin_start = enter_start + bin_index * bin_size
            overlap_start = max(slice_start, bin_start)
            overlap_end = min(slice_end, bin_start + bin_size)
            key = (bin_index, int(row["cpu"]))
            busy[key] = busy.get(key, 0) + max(0, overlap_end - overlap_start)
    output["cpu_busy_20ms"] = [
        {"bin_ms": bin_index * 20, "cpu": cpu, "busy_pct": round(duration / bin_size * 100, 1)}
        for (bin_index, cpu), duration in sorted(busy.items())
        if duration / bin_size >= 0.85
    ]
    for phase in ("enter", "recents", "return"):
        start = windows[phase][0]
        end = windows[phase][1]
        phase_bins = {}
        for row in sched_rows:
            slice_start = max(int(row["ts"]), start)
            slice_end = min(int(row["ts"]) + int(row["dur"]), end)
            if slice_end <= slice_start:
                continue
            first_bin = (slice_start - start) // bin_size
            last_bin = (slice_end - 1 - start) // bin_size
            for bin_index in range(first_bin, last_bin + 1):
                bin_start = start + bin_index * bin_size
                overlap_start = max(slice_start, bin_start)
                overlap_end = min(slice_end, bin_start + bin_size)
                key = (bin_index, int(row["cpu"]))
                phase_bins[key] = phase_bins.get(key, 0) + max(0, overlap_end - overlap_start)
        counts = {}
        for (bin_index, _cpu), duration in phase_bins.items():
            if duration / bin_size >= 0.85:
                counts[bin_index] = counts.get(bin_index, 0) + 1
        total_bins = max(1, (end - start + bin_size - 1) // bin_size)
        output["windows"][phase]["core_saturation"] = {
            "total_bins": total_bins,
            "ge4": sum(value >= 4 for value in counts.values()),
            "ge6": sum(value >= 6 for value in counts.values()),
            "all8": sum(value >= 8 for value in counts.values()),
            "max": max(counts.values(), default=0),
        }
    output["cpu_frequency"] = rows(tp, f"""
      select ct.cpu,min(c.value) min_khz,round(avg(c.value),0) avg_khz,max(c.value) max_khz
      from counter c join cpu_counter_track ct on c.track_id=ct.id
      where ct.name='cpufreq' and c.ts between {enter_start} and {return_end}
      group by ct.cpu order by ct.cpu
    """)
    output["counter_tracks"] = rows(tp, """
      select name,count(*) samples from counter_track ct join counter c on c.track_id=ct.id
      where lower(name) like '%gpu%' or lower(name) like '%freq%'
      group by name order by samples desc limit 40
    """)
    tp.close()
    return output


def print_rows(title, data, limit=None):
    print(f"\n  {title}")
    for row in data[:limit]:
        print(f"    {row}")
    if not data:
        print("    <none>")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result_root", type=Path)
    args = parser.parse_args()
    for run_dir in sorted(args.result_root.glob("run-*")):
        result = analyze_run(run_dir)
        print(f"\n========== {result['run']} ==========")
        print(f"bounds={result['bounds']}")
        for phase, window in result["windows"].items():
            print(f"\n-- {phase} ({window['duration_ms']:.1f} ms) --")
            print_rows("process runtime", window["process_runtime"])
            print_rows("Moonlight by CPU", window["moonlight_by_cpu"])
            print_rows("top threads", window["top_threads"], 14)
            print_rows("runnable delay", window["runnable"], 14)
            print_rows("Full/Partial jank", window["jank"])
            print_rows("long slices", window["long_slices"], 16)
        print_rows("CPU frequency", result["cpu_frequency"])
        print_rows("20 ms bins with >=85% core busy", result["cpu_busy_20ms"], 120)
        print_rows("GPU/frequency counter tracks", result["counter_tracks"])


if __name__ == "__main__":
    main()

import argparse
import re
import sys
from pathlib import Path

PERFETTO_SITE = Path(r"D:\Projects\HyperOS4-Sheng-DSU\tools\perfetto-python")
if PERFETTO_SITE.exists():
    sys.path.insert(0, str(PERFETTO_SITE))

from perfetto.trace_processor import TraceProcessor


TARGET = """
  (p.name = 'com.miui.home'
   or p.name like 'com.tencent.jkchess%'
   or p.name = 'com.android.systemui'
   or p.name = 'system_server'
   or lower(p.name) like '%surfaceflinger%')
"""


def query_rows(tp, sql):
    result = tp.query(sql)
    columns = result.column_names
    return [{column: getattr(row, column) for column in columns} for row in result]


def parse_phases(path):
    phases = {}
    for line in path.read_text(encoding="ascii").splitlines():
        match = re.match(r"phase=(\S+) uptime=([0-9.]+)", line)
        if match:
            phases[match.group(1)] = int(float(match.group(2)) * 1_000_000_000)
    return phases


def parse_native_yields(path, start, end):
    values = []
    pattern = re.compile(
        r"mono=([0-9.]+) native-yield (\d+).*nativeDeliveryUs=(-?\d+).*nativeYieldUs=(-?\d+)"
    )
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = pattern.search(line)
        if not match:
            continue
        timestamp = int(float(match.group(1)) * 1_000_000_000)
        if start <= timestamp <= end:
            values.append({
                "ts": timestamp,
                "pid": int(match.group(2)),
                "delivery_us": int(match.group(3)),
                "write_us": int(match.group(4)),
            })
    return values


def overlap(alias, start, end):
    return f"max(0, min({alias}.ts + {alias}.dur, {end}) - max({alias}.ts, {start}))"


def analyze_window(tp, name, start, end, game_pid):
    sched_overlap = overlap("s", start, end)
    state_overlap = overlap("st", start, end)
    window = {
        "name": name,
        "start": start,
        "end": end,
        "duration_ms": (end - start) / 1e6,
    }
    target = f"({TARGET} or p.pid = {game_pid})"
    window["runtime"] = query_rows(tp, f"""
      select p.name process,round(sum({sched_overlap})/1e6,3) run_ms
      from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
      where s.ts < {end} and s.ts+s.dur > {start} and {target}
      group by p.name order by run_ms desc
    """)
    window["game_cpu"] = query_rows(tp, f"""
      select s.cpu,round(sum({sched_overlap})/1e6,3) run_ms
      from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
      where s.ts < {end} and s.ts+s.dur > {start} and p.pid = {game_pid}
      group by s.cpu order by s.cpu
    """)
    window["top_threads"] = query_rows(tp, f"""
      select p.name process,t.name thread,round(sum({sched_overlap})/1e6,3) run_ms,
             group_concat(distinct s.cpu) cpus
      from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
      where s.ts < {end} and s.ts+s.dur > {start} and {target}
      group by p.upid,t.utid order by run_ms desc limit 24
    """)
    window["runnable"] = query_rows(tp, f"""
      select p.name process,t.name thread,round(sum({state_overlap})/1e6,3) runnable_ms,
             round(max(st.dur)/1e6,3) max_runnable_ms
      from thread_state st join thread t on st.utid=t.utid join process p on t.upid=p.upid
      where st.state='R' and st.ts < {end} and st.ts+st.dur > {start} and {target}
      group by p.upid,t.utid having runnable_ms >= 0.25
      order by runnable_ms desc limit 24
    """)
    window["jank"] = query_rows(tp, f"""
      select coalesce(p.name,'SurfaceFlinger') process,f.layer_name,f.present_type,
             f.jank_type,f.jank_severity_type,f.gpu_composition,
             round((f.ts-{start})/1e6,3) offset_ms,round(f.dur/1e6,3) dur_ms
      from actual_frame_timeline_slice f left join process p on f.upid=p.upid
      where f.ts < {end} and f.ts+f.dur > {start}
        and f.jank_severity_type in ('Full','Partial')
      order by f.ts
    """)
    window["long_slices"] = query_rows(tp, f"""
      select p.name process,t.name thread,s.name,count(*) count,
             round(sum(s.dur)/1e6,3) total_ms,round(max(s.dur)/1e6,3) max_ms
      from slice s join thread_track tt on s.track_id=tt.id
        join thread t on tt.utid=t.utid join process p on t.upid=p.upid
      where s.ts < {end} and s.ts+s.dur > {start} and s.dur >= 5000000 and {target}
      group by p.upid,t.utid,s.name order by max_ms desc limit 30
    """)
    return window


def print_rows(label, values, limit=None):
    print(f"  {label}:")
    if not values:
        print("    <none>")
        return
    for value in values[:limit]:
        print(f"    {value}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result_dir", type=Path)
    args = parser.parse_args()
    phases = parse_phases(args.result_dir / "phases.txt")
    game_pid_file = args.result_dir / "game-pid.txt"
    game_pid = int(game_pid_file.read_text(encoding="ascii").split()[0]) if game_pid_file.exists() else None
    tp = TraceProcessor(trace=str(args.result_dir / "trace.perfetto-trace"))
    try:
        bounds = query_rows(tp, "select start_ts,end_ts,(end_ts-start_ts)/1e6 dur_ms from trace_bounds")[0]
        print(f"trace_bounds={bounds}")
        print_rows("matching processes", query_rows(tp, f"""
          select p.upid,p.pid,p.name from process p
          where p.name='com.miui.home' or p.name like 'com.tencent.jkchess%'
             or p.name='com.android.systemui' or p.name='system_server'
             or lower(p.name) like '%surfaceflinger%'
             or p.pid={game_pid if game_pid is not None else -1}
          order by p.pid
        """))
        print_rows("cgroup raw event names", query_rows(tp, """
          select name,count(*) count from raw where lower(name) like '%cgroup%'
          group by name order by count desc
        """))

        native_yields = parse_native_yields(
            args.result_dir / "module.log", phases["stress_start"], phases["stress_complete"]
        )
        print_rows("native yields in stress", native_yields)
        for index, event in enumerate(native_yields, 1):
            print(f"\n== native_yield_{index} post-write CPU placement ==")
            for label, offset_start, offset_end in (
                ("0-100ms", 0, 100_000_000),
                ("100-300ms", 100_000_000, 300_000_000),
                ("300-600ms", 300_000_000, 600_000_000),
            ):
                start = event["ts"] + offset_start
                end = event["ts"] + offset_end
                sched_overlap = overlap("s", start, end)
                values = query_rows(tp, f"""
                  select s.cpu,round(sum({sched_overlap})/1e6,3) run_ms
                  from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
                  where s.ts < {end} and s.ts+s.dur > {start}
                    and p.pid = {event['pid']}
                  group by s.cpu order by s.cpu
                """)
                print_rows(label, values)

        for round_no in range(1, 5):
            before = phases[f"round_{round_no}_before_gesture"]
            after_gesture = phases[f"round_{round_no}_after_gesture"]
            after_tap = phases[f"round_{round_no}_after_tap"]
            next_start = phases.get(f"round_{round_no + 1}_before_gesture", phases["stress_complete"])
            windows = [
                analyze_window(tp, f"round_{round_no}_entry", before,
                               min(after_gesture + 1_200_000_000, next_start),
                               game_pid if game_pid is not None else native_yields[0]["pid"]),
                analyze_window(tp, f"round_{round_no}_return", after_tap, next_start,
                               game_pid if game_pid is not None else native_yields[0]["pid"]),
            ]
            for window in windows:
                print(f"\n== {window['name']} duration={window['duration_ms']:.1f}ms ==")
                print_rows("runtime", window["runtime"])
                print_rows("game by CPU", window["game_cpu"])
                print_rows("top threads", window["top_threads"], 16)
                print_rows("runnable delay", window["runnable"], 16)
                print_rows("Full/Partial jank", window["jank"])
                print_rows("long slices", window["long_slices"], 18)
    finally:
        tp.close()


if __name__ == "__main__":
    main()

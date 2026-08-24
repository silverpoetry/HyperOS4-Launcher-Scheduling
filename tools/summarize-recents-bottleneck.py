import argparse
import os
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

PERFETTO_SITE = os.environ.get("PERFETTO_PYTHON")
if PERFETTO_SITE:
    sys.path.insert(0, PERFETTO_SITE)

from perfetto.trace_processor import TraceProcessor


def rows(tp, sql):
    result = tp.query(sql)
    columns = result.column_names
    return [{column: getattr(row, column) for column in columns} for row in result]


def read_phases(path):
    result = {}
    for line in path.read_text(encoding="ascii").splitlines():
        match = re.match(r"phase=(\S+) uptime=([0-9.]+)", line)
        if match:
            result[match.group(1)] = int(float(match.group(2)) * 1_000_000_000)
    return result


def phase_windows(phase):
    windows = []
    for index in range(1, 5):
        before = phase[f"round_{index}_before_gesture"]
        after_gesture = phase[f"round_{index}_after_gesture"]
        after_tap = phase[f"round_{index}_after_tap"]
        next_start = phase.get(f"round_{index + 1}_before_gesture", phase["stress_complete"])
        windows.append((f"round_{index}_entry", before, min(after_gesture + 1_200_000_000, next_start)))
        windows.append((f"round_{index}_return", after_tap, next_start))
    return windows


def find_phase(ts, windows):
    for name, start, end in windows:
        if start <= ts < end:
            return name
    return "outside"


def percentile(values, fraction):
    if not values:
        return 0.0
    values = sorted(values)
    index = min(len(values) - 1, round((len(values) - 1) * fraction))
    return values[index]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result_dir", type=Path)
    args = parser.parse_args()
    phase = read_phases(args.result_dir / "phases.txt")
    windows = phase_windows(phase)
    tp = TraceProcessor(trace=str(args.result_dir / "trace.perfetto-trace"))
    try:
        draws = rows(tp, """
          select d.id,d.ts,d.dur,d.name,t.utid,d.track_id
          from slice d join thread_track tt on d.track_id=tt.id
          join thread t on tt.utid=t.utid join process p on t.upid=p.upid
          where p.name='com.miui.home' and t.name='1.raster'
            and d.name like 'GPURasterizer::Draw%'
          order by d.ts
        """)
        by_phase = defaultdict(list)
        long_draws = []
        for draw in draws:
            name = find_phase(draw["ts"], windows)
            if name == "outside":
                continue
            children = rows(tp, f"""
              select id,ts,dur,name,depth,track_id from slice where parent_id={draw['id']} order by ts
            """)
            encode0 = sum(c["dur"] for c in children if c["name"] == "SurfaceFrame::Encode V:0") / 1e6
            encode1 = sum(c["dur"] for c in children if c["name"] == "SurfaceFrame::Encode V:1") / 1e6
            paint = sum(c["dur"] for c in children if c["name"] == "LayerTree::Paint") / 1e6
            present = sum(c["dur"] for c in children if c["name"] == "SurfaceFrame::Present") / 1e6
            match = re.search(r"Draw (\d+)", draw["name"])
            token = int(match.group(1)) if match else -1
            layers = rows(tp, f"""
              select distinct layer_name from actual_frame_timeline_slice
              where surface_frame_token={token} and layer_name is not null
            """)
            item = {
                "phase": name,
                "id": draw["id"],
                "ts": draw["ts"],
                "dur": draw["dur"],
                "utid": draw["utid"],
                "track_id": draw["track_id"],
                "token": token,
                "draw_ms": draw["dur"] / 1e6,
                "encode_v0_ms": encode0,
                "encode_v1_ms": encode1,
                "paint_ms": paint,
                "present_ms": present,
                "layers": [v["layer_name"] for v in layers],
            }
            by_phase[name].append(item)
            if item["draw_ms"] >= 8.0:
                long_draws.append(item)

        print("# Launcher raster by phase")
        for name, _, _ in windows:
            values = by_phase[name]
            draw_values = [v["draw_ms"] for v in values]
            encode0_values = [v["encode_v0_ms"] for v in values]
            print({
                "phase": name,
                "frames": len(values),
                "draw_over_8ms": sum(v >= 8 for v in draw_values),
                "draw_p50_ms": round(statistics.median(draw_values), 3) if values else 0,
                "draw_p95_ms": round(percentile(draw_values, .95), 3),
                "draw_max_ms": round(max(draw_values), 3) if values else 0,
                "encode_v0_p95_ms": round(percentile(encode0_values, .95), 3),
                "encode_v0_max_ms": round(max(encode0_values), 3) if values else 0,
            })

        print("\n# Three longest Launcher raster frames per phase")
        for phase_name, _, _ in windows:
            selected = sorted((v for v in long_draws if v["phase"] == phase_name),
                              key=lambda v: v["draw_ms"], reverse=True)[:3]
            for item in selected:
                start = item["ts"]
                end = start + item["dur"]
                accounting = rows(tp, f"""
                  select state,sum(max(0,min(ts+dur,{end})-max(ts,{start})))/1e6 state_ms
                  from thread_state where utid={item['utid']} and ts < {end} and ts+dur > {start}
                  group by state
                """)
                states = {v["state"]: v["state_ms"] for v in accounting}
                summary = {
                "phase": item["phase"],
                "token": item["token"],
                "draw_ms": round(item["draw_ms"], 3),
                "encode_v0_ms": round(item["encode_v0_ms"], 3),
                "encode_v1_ms": round(item["encode_v1_ms"], 3),
                "paint_ms": round(item["paint_ms"], 3),
                "present_ms": round(item["present_ms"], 3),
                "running_ms": round(states.get("Running", 0), 3),
                "runnable_ms": round(states.get("R", 0) + states.get("R+", 0), 3),
                "sleep_ms": round(states.get("S", 0), 3),
                "layers": item["layers"],
                }
                print(summary)
                encode = rows(tp, f"""
                  select id,ts,dur,depth,track_id from slice
                  where parent_id={item['id']} and name='SurfaceFrame::Encode V:0'
                  order by dur desc limit 1
                """)
                if encode and encode[0]["dur"] >= 6_000_000:
                    value = encode[0]
                    encode_end = value["ts"] + value["dur"]
                    nested = rows(tp, f"""
                      select name,depth,round((ts-{value['ts']})/1e6,3) offset_ms,
                             round(dur/1e6,3) dur_ms
                      from slice where track_id={value['track_id']}
                        and ts >= {value['ts']} and ts+dur <= {encode_end}
                        and depth > {value['depth']} and dur >= 50000
                      order by dur desc limit 12
                    """)
                    for child in nested:
                        print("  ", child)

        snapshots = rows(tp, """
          select s.id,s.ts,s.dur,t.utid
          from slice s join thread_track tt on s.track_id=tt.id
          join thread t on tt.utid=t.utid join process p on t.upid=p.upid
          where p.name='system_server' and t.name='TaskSnapshotPer'
            and s.name like 'StoreWriteQueueItem#%'
          order by s.ts
        """)
        print("\n# Task snapshot persistence")
        for item in snapshots:
            name = find_phase(item["ts"], windows)
            if name == "outside":
                continue
            start = item["ts"]
            end = start + item["dur"]
            accounting = rows(tp, f"""
              select state,sum(max(0,min(ts+dur,{end})-max(ts,{start})))/1e6 state_ms
              from thread_state where utid={item['utid']} and ts < {end} and ts+dur > {start}
              group by state
            """)
            states = {v["state"]: v["state_ms"] for v in accounting}
            cpus = rows(tp, f"""
              select cpu,sum(max(0,min(ts+dur,{end})-max(ts,{start})))/1e6 run_ms
              from sched where utid={item['utid']} and ts < {end} and ts+dur > {start}
              group by cpu order by cpu
            """)
            print({
                "phase": name,
                "wall_ms": round(item["dur"] / 1e6, 3),
                "running_ms": round(states.get("Running", 0), 3),
                "runnable_ms": round(states.get("R", 0) + states.get("R+", 0), 3),
                "blocked_ms": round(states.get("D", 0), 3),
                "cpu_runtime_ms": {v["cpu"]: round(v["run_ms"], 3) for v in cpus},
            })

        callbacks = rows(tp, """
          select s.id,s.ts,s.dur,t.utid
          from slice s join thread_track tt on s.track_id=tt.id
          join thread t on tt.utid=t.utid join process p on t.upid=p.upid
          where p.name='com.miui.home' and t.tid=p.pid
            and s.name='CALLBACK_ANIMATION' and s.dur >= 20000000
          order by s.ts
        """)
        print("\n# Long Launcher main callbacks")
        for item in callbacks:
            name = find_phase(item["ts"], windows)
            if name == "outside":
                continue
            start = item["ts"]
            end = start + item["dur"]
            accounting = rows(tp, f"""
              select state,sum(max(0,min(ts+dur,{end})-max(ts,{start})))/1e6 state_ms
              from thread_state where utid={item['utid']} and ts < {end} and ts+dur > {start}
              group by state
            """)
            states = {v["state"]: v["state_ms"] for v in accounting}
            print({
                "phase": name,
                "wall_ms": round(item["dur"] / 1e6, 3),
                "running_ms": round(states.get("Running", 0), 3),
                "runnable_ms": round(states.get("R", 0) + states.get("R+", 0), 3),
                "sleep_ms": round(states.get("S", 0), 3),
            })
    finally:
        tp.close()


if __name__ == "__main__":
    main()

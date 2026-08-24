import math
import os
import re
import statistics
import sys
from pathlib import Path

PERFETTO_SITE = os.environ.get("PERFETTO_PYTHON")
if PERFETTO_SITE:
    sys.path.insert(0, PERFETTO_SITE)
from perfetto.trace_processor import TraceProcessor


def rows(tp, sql):
    result = tp.query(sql)
    columns = result.column_names
    return [{column: getattr(row, column) for column in columns} for row in result]


def phases(path):
    parsed = {}
    for line in path.read_text(encoding="ascii").splitlines():
        match = re.match(r"phase=(\S+) uptime=([0-9.]+)", line)
        if match:
            parsed[match.group(1)] = int(float(match.group(2)) * 1_000_000_000)
    return parsed


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = (len(ordered) - 1) * fraction
    low = math.floor(rank)
    high = math.ceil(rank)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


def source_pid(directory):
    for filename in ("game-pid.txt", "source-pid.txt"):
        path = directory / filename
        if path.exists() and path.read_text(encoding="ascii").split():
            return int(path.read_text(encoding="ascii").split()[0])
    raise RuntimeError(f"source PID missing in {directory}")


def summarize(label, directory):
    phase = phases(directory / "phases.txt")
    pid = source_pid(directory)
    tp = TraceProcessor(trace=str(directory / "trace.perfetto-trace"))
    totals = {
        "entry_ms": 0.0,
        "source_ms": 0.0,
        "source_little_ms": 0.0,
        "source_big_ms": 0.0,
        "launcher_ms": 0.0,
        "system_server_ms": 0.0,
        "sf_ms": 0.0,
        "launcher_runnable_ms": 0.0,
        "launcher_runnable_max_ms": 0.0,
        "launcher_frames": [],
        "sf_frames": [],
        "callback_frames": [],
        "full_partial": [],
    }
    try:
        for round_no in range(1, 5):
            start = phase[f"round_{round_no}_before_gesture"]
            after = phase[f"round_{round_no}_after_gesture"]
            next_start = phase.get(f"round_{round_no + 1}_before_gesture", phase["stress_complete"])
            end = min(after + 1_200_000_000, next_start)
            totals["entry_ms"] += (end - start) / 1e6
            runtime = rows(tp, f"""
                select p.pid,p.name process, s.cpu, sum(max(0,min(s.ts+s.dur,{end})-max(s.ts,{start})))/1e6 run_ms
                from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
                where s.ts < {end} and s.ts+s.dur > {start}
                  and (p.pid={pid} or p.name='com.miui.home' or p.name='system_server'
                       or lower(p.name) like '%surfaceflinger%')
                group by p.name,s.cpu
            """)
            for item in runtime:
                process = item["process"]
                value = float(item["run_ms"] or 0)
                if process == "com.miui.home":
                    totals["launcher_ms"] += value
                elif process == "system_server":
                    totals["system_server_ms"] += value
                elif "surfaceflinger" in process.lower():
                    totals["sf_ms"] += value
                if int(item["pid"] or -1) == pid:
                    totals["source_ms"] += value
                    if int(item["cpu"]) <= 2:
                        totals["source_little_ms"] += value
                    else:
                        totals["source_big_ms"] += value

            runnable = rows(tp, f"""
                select sum(max(0,min(st.ts+st.dur,{end})-max(st.ts,{start})))/1e6 run_ms,
                       max(st.dur)/1e6 max_ms
                from thread_state st join thread t on st.utid=t.utid join process p on t.upid=p.upid
                where st.state='R' and st.ts < {end} and st.ts+st.dur > {start}
                  and p.name='com.miui.home'
                  and (t.name='1.ui' or t.name='1.raster' or t.name='com.miui.home'
                       or t.name='rt-launcher-mai')
            """)
            if runnable:
                totals["launcher_runnable_ms"] += float(runnable[0]["run_ms"] or 0)
                totals["launcher_runnable_max_ms"] = max(
                    totals["launcher_runnable_max_ms"], float(runnable[0]["max_ms"] or 0)
                )

            frames = rows(tp, f"""
                select coalesce(p.name,'SurfaceFlinger') process,f.dur/1e6 dur_ms,
                       f.jank_severity_type severity,f.jank_type jank_type,f.layer_name layer
                from actual_frame_timeline_slice f left join process p on f.upid=p.upid
                where f.ts < {end} and f.ts+f.dur > {start}
                  and (p.name='com.miui.home' or lower(p.name) like '%surfaceflinger%'
                       or f.jank_severity_type in ('Full','Partial'))
            """)
            for frame in frames:
                value = float(frame["dur_ms"] or 0)
                if frame["process"] == "com.miui.home":
                    totals["launcher_frames"].append(value)
                elif "surfaceflinger" in frame["process"].lower():
                    totals["sf_frames"].append(value)
                if frame["severity"] in ("Full", "Partial"):
                    totals["full_partial"].append(frame)

            callbacks = rows(tp, f"""
                select s.dur/1e6 dur_ms
                from slice s join thread_track tt on s.track_id=tt.id
                  join thread t on tt.utid=t.utid join process p on t.upid=p.upid
                where s.ts < {end} and s.ts+s.dur > {start}
                  and p.name='com.miui.home' and s.name='CALLBACK_ANIMATION'
            """)
            totals["callback_frames"].extend(float(item["dur_ms"]) for item in callbacks)
    finally:
        tp.close()

    source_big_pct = 100 * totals["source_big_ms"] / totals["source_ms"] if totals["source_ms"] else 0
    return {
        "label": label,
        "entry_ms": totals["entry_ms"],
        "source_ms": totals["source_ms"],
        "source_big_pct": source_big_pct,
        "launcher_ms": totals["launcher_ms"],
        "system_server_ms": totals["system_server_ms"],
        "sf_ms": totals["sf_ms"],
        "launcher_runnable_ms": totals["launcher_runnable_ms"],
        "launcher_runnable_max_ms": totals["launcher_runnable_max_ms"],
        "launcher_p95_ms": percentile(totals["launcher_frames"], 0.95),
        "launcher_max_ms": max(totals["launcher_frames"], default=0),
        "sf_p95_ms": percentile(totals["sf_frames"], 0.95),
        "sf_max_ms": max(totals["sf_frames"], default=0),
        "callback_p95_ms": percentile(totals["callback_frames"], 0.95),
        "callback_max_ms": max(totals["callback_frames"], default=0),
        "callback_over_8": sum(value > 8.33 for value in totals["callback_frames"]),
        "callback_over_16": sum(value > 16.67 for value in totals["callback_frames"]),
        "full_partial": len(totals["full_partial"]),
        "jank": totals["full_partial"],
    }


def main():
    definitions = [argument.split("=", 1) for argument in sys.argv[1:]]
    results = [summarize(label, Path(path)) for label, path in definitions]
    keys = [
        "entry_ms", "source_ms", "source_big_pct", "launcher_ms", "system_server_ms", "sf_ms",
        "launcher_runnable_ms", "launcher_runnable_max_ms", "launcher_p95_ms", "launcher_max_ms",
        "sf_p95_ms", "sf_max_ms", "callback_p95_ms", "callback_max_ms", "callback_over_8",
        "callback_over_16", "full_partial",
    ]
    print("metric," + ",".join(result["label"] for result in results))
    for key in keys:
        print(key + "," + ",".join(f"{result[key]:.3f}" for result in results))
    for result in results:
        print(f"\n[{result['label']}] Full/Partial")
        for item in result["jank"]:
            print(item)


if __name__ == "__main__":
    main()

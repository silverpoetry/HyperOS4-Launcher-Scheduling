import argparse
import importlib.util
import re
import statistics
from collections import defaultdict
from pathlib import Path


def load_analyzer():
    path = Path(__file__).with_name("analyze-validated-recents.py")
    spec = importlib.util.spec_from_file_location("validated_analyzer", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def scalar(rows, key="value"):
    return float(rows[0][key]) if rows else 0.0


def collect(directory, analyzer, source_process):
    phases = analyzer.read_phases(directory / "phases.txt")
    start = phases["before_recents"]
    end = phases["after_recents_command"] + 800_000_000
    sched_overlap = analyzer.overlap("s", start, end)
    state_overlap = analyzer.overlap("st", start, end)
    tp = analyzer.TraceProcessor(trace=str(directory / "trace.perfetto-trace"))
    values = {"name": directory.name}
    try:
        process_rows = analyzer.query_rows(tp, f"""
          select p.name process,sum({sched_overlap})/1e6 run_ms
          from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
          where s.ts<{end} and s.ts+s.dur>{start}
          group by p.upid
        """)
        processes = {row["process"]: float(row["run_ms"]) for row in process_rows}
        aliases = {
            "launcher": "com.miui.home",
            "system_server": "system_server",
            "surfaceflinger": "/system/bin/surfaceflinger",
            "systemui": "com.android.systemui",
            "composer": "/vendor/bin/hw/vendor.qti.hardware.display.composer-service",
            "source": source_process,
            "widget": "com.xiaomi.smarthome:widgetControl",
            "weather": "com.miui.weather2",
            "smarthome": "com.xiaomi.smarthome",
            "trace_probes": "/system/bin/traced_probes",
            "logd": "/system/bin/logd",
            "codec": "media.hwcodec",
            "crtc": "crtc_commit:176",
            "wallpaper": "com.miui.miwallpaper",
        }
        for key, process in aliases.items():
            values[key] = processes.get(process, 0.0)
        values["desktop_peers"] = values["widget"] + values["weather"] + values["smarthome"]

        threads = analyzer.query_rows(tp, f"""
          select t.name thread,sum({sched_overlap})/1e6 run_ms
          from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
          where s.ts<{end} and s.ts+s.dur>{start} and p.name='com.miui.home'
          group by t.name
        """)
        for row in threads:
            if row["thread"] in ("1.raster", "1.ui", "IplrVkFenceWait", "IplrVkResMgr"):
                values[f"run_{row['thread']}"] = float(row["run_ms"])

        runnable = analyzer.query_rows(tp, f"""
          select t.name thread,sum({state_overlap})/1e6 wait_ms,max(st.dur)/1e6 max_wait_ms
          from thread_state st join thread t on st.utid=t.utid join process p on t.upid=p.upid
          where st.state in ('R','R+') and st.ts<{end} and st.ts+st.dur>{start}
            and p.name='com.miui.home' group by t.name
        """)
        for row in runnable:
            if row["thread"] in ("1.raster", "1.ui", "IplrVkFenceWait", "IplrVkResMgr"):
                values[f"wait_{row['thread']}"] = float(row["wait_ms"])
                values[f"maxwait_{row['thread']}"] = float(row["max_wait_ms"])

        stages = analyzer.query_rows(tp, f"""
          select case
                   when sl.name like 'GPURasterizer::Draw%' then 'draw'
                   when sl.name like 'SurfaceFrame::Encode%' then 'encode'
                   when sl.name like 'LayerTree::Paint%' then 'paint'
                   else 'other'
                 end stage,count(*) count,sum(sl.dur)/1e6 total_ms,max(sl.dur)/1e6 max_ms,
                 sum(case when sl.dur>6944444 then 1 else 0 end) over_budget
          from slice sl join thread_track tt on sl.track_id=tt.id
          join thread t on tt.utid=t.utid join process p on t.upid=p.upid
          where sl.ts<{end} and sl.ts+sl.dur>{start} and p.name='com.miui.home'
            and (sl.name like 'GPURasterizer::Draw%' or sl.name like 'SurfaceFrame::Encode%'
                 or sl.name like 'LayerTree::Paint%') group by stage
        """)
        for row in stages:
            stage = row["stage"]
            values[f"{stage}_count"] = float(row["count"])
            values[f"{stage}_total"] = float(row["total_ms"])
            values[f"{stage}_max"] = float(row["max_ms"])
            values[f"{stage}_over"] = float(row["over_budget"])

        snapshot = analyzer.query_rows(tp, f"""
          select sum(sl.dur)/1e6 value from slice sl join thread_track tt on sl.track_id=tt.id
          join thread t on tt.utid=t.utid join process p on t.upid=p.upid
          where sl.ts<{end} and sl.ts+sl.dur>{start} and p.name='system_server'
            and t.name='TaskSnapshotPer' and sl.name like 'StoreWriteQueueItem#%'
        """)
        values["snapshot_store"] = scalar(snapshot)

        source_cpus = analyzer.query_rows(tp, f"""
          select s.cpu,sum({sched_overlap})/1e6 run_ms
          from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
          where s.ts<{end} and s.ts+s.dur>{start} and p.name='{source_process}'
          group by s.cpu
        """)
        values["source_perf"] = sum(float(row["run_ms"]) for row in source_cpus if int(row["cpu"]) >= 3)

        jank = analyzer.query_rows(tp, f"""
          select coalesce(p.name,'SurfaceFlinger') process,f.jank_severity_type,count(*) count
          from actual_frame_timeline_slice f left join process p on f.upid=p.upid
          where f.ts<{end} and f.ts+f.dur>{start}
            and f.jank_severity_type in ('Full','Partial')
          group by process,f.jank_severity_type
        """)
        values["jank_full"] = sum(int(row["count"]) for row in jank if row["jank_severity_type"] == "Full")
        values["jank_partial"] = sum(int(row["count"]) for row in jank if row["jank_severity_type"] == "Partial")
        values["systemui_full"] = sum(
            int(row["count"]) for row in jank
            if row["process"] == "com.android.systemui" and row["jank_severity_type"] == "Full"
        )
    finally:
        tp.close()

    deltas = []
    module_log = directory / "module.log"
    for line in module_log.read_text(encoding="utf-8", errors="replace").splitlines() if module_log.exists() else ():
        match = re.search(r"mono=([0-9.]+).*native-yield", line)
        if match:
            delta = float(match.group(1)) - phases["before_recents"] / 1e9
            if -0.1 <= delta <= 1.0:
                deltas.append(delta * 1000)
    values["yield_ms"] = min(deltas) if deltas else -1.0
    return values


def summarize(label, runs):
    print(f"\n## {label} ({len(runs)} runs)")
    keys = (
        "yield_ms", "source", "source_perf", "desktop_peers", "launcher", "system_server",
        "surfaceflinger", "systemui", "composer", "codec", "crtc", "wallpaper",
        "run_1.ui", "wait_1.ui",
        "run_1.raster", "wait_1.raster", "draw_over", "draw_total", "draw_max",
        "encode_over", "snapshot_store", "jank_full", "jank_partial", "systemui_full",
    )
    for key in keys:
        samples = [run.get(key, 0.0) for run in runs]
        print(f"{key}: avg={statistics.mean(samples):.3f} median={statistics.median(samples):.3f} "
              f"range={min(samples):.3f}-{max(samples):.3f}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--a", nargs="+", type=Path, required=True)
    parser.add_argument("--b", nargs="+", type=Path, required=True)
    parser.add_argument("--source", default="com.android.fileexplorer")
    parser.add_argument("--a-label", default="A")
    parser.add_argument("--b-label", default="B")
    args = parser.parse_args()
    analyzer = load_analyzer()
    a_runs = [collect(path, analyzer, args.source) for path in args.a]
    b_runs = [collect(path, analyzer, args.source) for path in args.b]
    for run in a_runs + b_runs:
        print(run)
    summarize(args.a_label, a_runs)
    summarize(args.b_label, b_runs)


if __name__ == "__main__":
    main()

import argparse
import re
import sys
from pathlib import Path

PERFETTO_SITE = Path(r"D:\Projects\HyperOS4-Sheng-DSU\tools\perfetto-python")
if PERFETTO_SITE.exists():
    sys.path.insert(0, str(PERFETTO_SITE))

from perfetto.trace_processor import TraceProcessor


def rows(tp, sql):
    result = tp.query(sql)
    columns = result.column_names
    return [{column: getattr(row, column) for column in columns} for row in result]


def phases(path):
    result = {}
    for line in path.read_text(encoding="ascii").splitlines():
        match = re.match(r"phase=(\S+) uptime=([0-9.]+)", line)
        if match:
            result[match.group(1)] = int(float(match.group(2)) * 1_000_000_000)
    return result


def windows_sql(markers):
    values = []
    for index in range(1, 6):
        values.append(f"({index},{markers[f'round_{index}_entry_start']},{markers[f'round_{index}_return_start']})")
    return ",".join(values)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result_dir", type=Path)
    args = parser.parse_args()
    marker = phases(args.result_dir / "phases.txt")
    windows = windows_sql(marker)
    tp = TraceProcessor(trace=str(args.result_dir / "trace.perfetto-trace"))
    try:
        print(f"result={args.result_dir}")
        print(f"policy0_before={args.result_dir.joinpath('policy0-before.txt').read_text().strip()}")
        print(f"policy0_after={args.result_dir.joinpath('policy0-after.txt').read_text().strip()}")
        print("threads_before:")
        print(args.result_dir.joinpath("threads-before.txt").read_text(encoding="utf-8", errors="replace").strip())

        frame = rows(tp, f"""
          with windows(round,start_ts,end_ts) as (values {windows})
          select coalesce(p.name,'SurfaceFlinger') process,
                 count(*) frames,
                 round(avg(f.dur)/1e6,3) avg_ms,
                 round(max(f.dur)/1e6,3) max_ms,
                 sum(case when f.jank_severity_type='Full' then 1 else 0 end) full_jank,
                 sum(case when f.jank_severity_type='Partial' then 1 else 0 end) partial_jank
          from windows w join actual_frame_timeline_slice f
            on f.ts < w.end_ts and f.ts+f.dur > w.start_ts
          left join process p on f.upid=p.upid
          where p.name in ('com.miui.home','com.android.systemui')
             or lower(p.name) like '%surfaceflinger%'
          group by process order by process
        """)
        print("frame_summary:")
        for value in frame:
            print(value)

        runtime = rows(tp, f"""
          with windows(round,start_ts,end_ts) as (values {windows})
          select t.name thread,s.cpu,
                 round(sum(max(0,min(s.ts+s.dur,w.end_ts)-max(s.ts,w.start_ts)))/1e6,3) run_ms
          from windows w join sched s on s.ts < w.end_ts and s.ts+s.dur > w.start_ts
          join thread t on s.utid=t.utid join process p on t.upid=p.upid
          where p.name='com.miui.home'
            and t.name in ('1.ui','1.raster','rt-launcher-mai','IplrVkResMgr','IplrVkFenceWait')
          group by t.name,s.cpu order by t.name,s.cpu
        """)
        print("launcher_runtime_by_cpu:")
        for value in runtime:
            print(value)

        runnable = rows(tp, f"""
          with windows(round,start_ts,end_ts) as (values {windows})
          select t.name thread,count(*) waits,
                 round(sum(max(0,min(st.ts+st.dur,w.end_ts)-max(st.ts,w.start_ts)))/1e6,3) runnable_ms,
                 round(max(st.dur)/1e6,3) max_runnable_ms
          from windows w join thread_state st on st.ts < w.end_ts and st.ts+st.dur > w.start_ts
          join thread t on st.utid=t.utid join process p on t.upid=p.upid
          where p.name='com.miui.home' and st.state='R'
            and t.name in ('1.ui','1.raster','rt-launcher-mai','IplrVkResMgr','IplrVkFenceWait')
          group by t.name order by runnable_ms desc
        """)
        print("launcher_runnable:")
        for value in runnable:
            print(value)
    finally:
        tp.close()


if __name__ == "__main__":
    main()

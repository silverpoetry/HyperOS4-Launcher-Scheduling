import argparse
import re
import sys
from pathlib import Path

PERFETTO_SITE = Path(r"D:\Projects\HyperOS4-Sheng-DSU\tools\perfetto-python")
if PERFETTO_SITE.exists():
    sys.path.insert(0, str(PERFETTO_SITE))

from perfetto.trace_processor import TraceProcessor


TARGETS = (
    "com.miui.home",
    "com.android.fileexplorer",
    "com.silverpoetry.moonlight",
    "com.android.systemui",
    "system_server",
    "/system/bin/surfaceflinger",
    "/vendor/bin/hw/vendor.qti.hardware.display.composer-service",
    "com.miui.screenshot",
    "/vendor/bin/hw/vendor.xiaomi.hardware.mimd@2.0-service",
)


def query_rows(tp, sql):
    result = tp.query(sql)
    names = result.column_names
    return [{name: getattr(row, name) for name in names} for row in result]


def read_phases(path):
    phases = {}
    for line in path.read_text(encoding="ascii").splitlines():
        match = re.match(r"phase=(\S+) uptime=([0-9.]+)", line)
        if match:
            phases[match.group(1)] = int(float(match.group(2)) * 1_000_000_000)
    return phases


def overlap(alias, start, end):
    return f"max(0,min({alias}.ts+{alias}.dur,{end})-max({alias}.ts,{start}))"


def target_sql(alias="p"):
    values = ",".join(f"'{name}'" for name in TARGETS)
    return f"{alias}.name in ({values})"


def print_rows(title, values, limit=20):
    print(f"\n{title}")
    if not values:
        print("  <none>")
    for value in values[:limit]:
        print(" ", value)


def analyze_window(tp, name, start, end):
    sched_overlap = overlap("s", start, end)
    state_overlap = overlap("st", start, end)
    slice_overlap = overlap("sl", start, end)
    print(f"\n\n===== {name} {(end-start)/1e6:.1f} ms =====")

    processes = query_rows(tp, f"""
      select p.name process,round(sum({sched_overlap})/1e6,3) run_ms
      from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
      where t.tid!=0 and s.ts<{end} and s.ts+s.dur>{start}
      group by p.upid order by run_ms desc limit 24
    """)
    print_rows("top processes", processes, 24)

    process_cpu = query_rows(tp, f"""
      select p.name process,s.cpu,round(sum({sched_overlap})/1e6,3) run_ms
      from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
      where s.ts<{end} and s.ts+s.dur>{start} and {target_sql()}
      group by p.upid,s.cpu order by p.name,s.cpu
    """)
    print_rows("target process runtime by CPU", process_cpu, 80)

    threads = query_rows(tp, f"""
      select p.name process,t.name thread,t.tid,
             round(sum({sched_overlap})/1e6,3) run_ms,
             group_concat(distinct s.cpu) cpus
      from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
      where s.ts<{end} and s.ts+s.dur>{start} and {target_sql()}
      group by p.upid,t.utid order by run_ms desc limit 50
    """)
    print_rows("target threads", threads, 50)

    runnable = query_rows(tp, f"""
      select p.name process,t.name thread,t.tid,
             round(sum({state_overlap})/1e6,3) runnable_ms,
             round(max(st.dur)/1e6,3) max_wait_ms
      from thread_state st join thread t on st.utid=t.utid join process p on t.upid=p.upid
      where st.state in ('R','R+') and st.ts<{end} and st.ts+st.dur>{start}
        and {target_sql()}
      group by p.upid,t.utid having runnable_ms>=0.2
      order by runnable_ms desc limit 40
    """)
    print_rows("target runnable delay", runnable, 40)

    key_states = query_rows(tp, f"""
      select p.name process,t.name thread,st.state,
             round(sum({state_overlap})/1e6,3) state_ms
      from thread_state st join thread t on st.utid=t.utid join process p on t.upid=p.upid
      where st.ts<{end} and st.ts+st.dur>{start} and
        ((p.name='com.miui.home' and t.name in
          ('com.miui.home','1.ui','1.raster','rt-launcher-mai','IplrVkResMgr','IplrVkFenceWait'))
         or (p.name='com.android.systemui' and t.name in ('ndroid.systemui','RenderThread','wmshell.main'))
         or (p.name='/system/bin/surfaceflinger' and t.name in
             ('surfaceflinger','RenderEngine','TimerDispatch')))
      group by p.upid,t.utid,st.state order by p.name,t.name,st.state
    """)
    print_rows("key thread state accounting", key_states, 80)

    jank = query_rows(tp, f"""
      select coalesce(p.name,'SurfaceFlinger') process,f.layer_name,
             f.jank_severity_type,f.jank_type,f.gpu_composition,
             round((f.ts-{start})/1e6,3) offset_ms,round(f.dur/1e6,3) dur_ms
      from actual_frame_timeline_slice f left join process p on f.upid=p.upid
      where f.ts<{end} and f.ts+f.dur>{start}
        and f.jank_severity_type in ('Full','Partial')
      order by f.ts
    """)
    print_rows("Full/Partial jank", jank, 80)

    long_slices = query_rows(tp, f"""
      select p.name process,t.name thread,sl.name,
             round(sum({slice_overlap})/1e6,3) total_ms,
             round(max(sl.dur)/1e6,3) max_ms,count(*) count
      from slice sl join thread_track tt on sl.track_id=tt.id
      join thread t on tt.utid=t.utid join process p on t.upid=p.upid
      where sl.ts<{end} and sl.ts+sl.dur>{start} and sl.dur>=1000000
        and {target_sql()}
      group by p.upid,t.utid,sl.name order by max_ms desc limit 40
    """)
    print_rows("long slices", long_slices, 40)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result_dir", type=Path)
    args = parser.parse_args()
    phases = read_phases(args.result_dir / "phases.txt")
    windows = {
        "entry": (phases["before_recents"], phases["after_recents_command"] + 800_000_000),
        "recents": (phases["after_recents_command"] + 800_000_000, phases["before_card_tap"]),
        "return": (phases["before_card_tap"], phases["after_card_tap"] + 1_000_000_000),
        "post": (phases["after_card_tap"] + 1_000_000_000, phases["complete"]),
    }
    tp = TraceProcessor(trace=str(args.result_dir / "trace.perfetto-trace"))
    try:
        for name, (start, end) in windows.items():
            analyze_window(tp, name, start, end)

        start, end = windows["entry"]
        first_work = query_rows(tp, f"""
          select p.name process,t.name thread,sl.name,
                 round((sl.ts-{start})/1e6,3) offset_ms,round(sl.dur/1e6,3) dur_ms
          from slice sl join thread_track tt on sl.track_id=tt.id
          join thread t on tt.utid=t.utid join process p on t.upid=p.upid
          where sl.ts between {start} and {end}
            and p.name in ('com.miui.home','com.android.systemui','/system/bin/surfaceflinger')
            and (sl.name like 'GPURasterizer::Draw%' or sl.name='CALLBACK_ANIMATION'
                 or sl.name like 'Choreographer#doFrame%' or sl.name like 'composite %')
          order by sl.ts limit 80
        """)
        print_rows("\nentry frame work timeline", first_work, 80)

        cpu_frequency = query_rows(tp, f"""
          select ct.cpu,min(c.value) min_khz,round(avg(c.value),0) avg_khz,max(c.value) max_khz
          from counter c join cpu_counter_track ct on c.track_id=ct.id
          where ct.name='cpufreq' and c.ts between {start} and {end}
          group by ct.cpu order by ct.cpu
        """)
        print_rows("entry CPU frequency", cpu_frequency, 16)

        counters = query_rows(tp, f"""
          select ct.name,min(c.value) minimum,round(avg(c.value),1) average,max(c.value) maximum,count(*) samples
          from counter c join counter_track ct on c.track_id=ct.id
          where c.ts between {start} and {end} and lower(ct.name) like '%gpu%'
          group by ct.id order by ct.name
        """)
        print_rows("entry GPU counters", counters, 40)
    finally:
        tp.close()


if __name__ == "__main__":
    main()

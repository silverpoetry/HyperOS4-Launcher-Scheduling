import argparse
import importlib.util
from pathlib import Path


def load_analyzer():
    path = Path(__file__).with_name("analyze-validated-recents.py")
    spec = importlib.util.spec_from_file_location("validated_analyzer", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def show(title, rows, limit=30):
    print(f"\n## {title}")
    if not rows:
        print("<none>")
    for row in rows[:limit]:
        print(row)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result_dir", type=Path)
    args = parser.parse_args()
    analyzer = load_analyzer()
    phases = analyzer.read_phases(args.result_dir / "phases.txt")
    start = phases["before_recents"]
    end = phases["after_recents_command"] + 800_000_000
    sched_overlap = analyzer.overlap("s", start, end)
    state_overlap = analyzer.overlap("st", start, end)
    tp = analyzer.TraceProcessor(trace=str(args.result_dir / "trace.perfetto-trace"))
    try:
        show("CPU busy", analyzer.query_rows(tp, f"""
          select s.cpu,round(sum({sched_overlap})/1e6,3) run_ms,
                 round(sum({sched_overlap})*100.0/({end-start}),1) busy_pct
          from sched s join thread t on s.utid=t.utid
          where t.tid!=0 and s.ts<{end} and s.ts+s.dur>{start}
          group by s.cpu order by s.cpu
        """))

        show("Launcher thread classes", analyzer.query_rows(tp, f"""
          select t.name thread,round(sum({sched_overlap})/1e6,3) run_ms,
                 group_concat(distinct s.cpu) cpus
          from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
          where s.ts<{end} and s.ts+s.dur>{start} and p.name='com.miui.home'
            and t.name in ('com.miui.home','1.ui','1.raster','rt-launcher-mai',
                           'IplrVkResMgr','IplrVkFenceWait')
          group by t.name order by run_ms desc
        """))

        show("Launcher runnable", analyzer.query_rows(tp, f"""
          select t.name thread,round(sum({state_overlap})/1e6,3) runnable_ms,
                 round(max(st.dur)/1e6,3) max_wait_ms
          from thread_state st join thread t on st.utid=t.utid join process p on t.upid=p.upid
          where st.state in ('R','R+') and st.ts<{end} and st.ts+st.dur>{start}
            and p.name='com.miui.home'
          group by t.name having runnable_ms>=0.2 order by runnable_ms desc
        """), 20)

        show("Other high-runtime processes by CPU", analyzer.query_rows(tp, f"""
          select p.name process,s.cpu,round(sum({sched_overlap})/1e6,3) run_ms
          from sched s join thread t on s.utid=t.utid join process p on t.upid=p.upid
          where s.ts<{end} and s.ts+s.dur>{start} and
            p.name in ('com.xiaomi.smarthome:widgetControl','com.xiaomi.smarthome',
                       'com.miui.weather2','com.android.fileexplorer',
                       'com.silverpoetry.moonlight')
          group by p.upid,s.cpu order by p.name,s.cpu
        """), 40)

        show("Launcher frame stages", analyzer.query_rows(tp, f"""
          select case
                   when sl.name like 'GPURasterizer::Draw%' then 'GPURasterizer::Draw'
                   when sl.name like 'SurfaceFrame::Encode%' then 'SurfaceFrame::Encode'
                   when sl.name like 'LayerTree::Paint%' then 'LayerTree::Paint'
                   when sl.name like 'AcquireNextImageKHR%' then 'AcquireNextImageKHR'
                   when sl.name like 'waitForBufferRelease%' then 'waitForBufferRelease'
                   when sl.name='CALLBACK_ANIMATION' then 'CALLBACK_ANIMATION'
                   else sl.name
                 end stage,
                 count(*) count,round(sum(sl.dur)/1e6,3) total_ms,
                 round(max(sl.dur)/1e6,3) max_ms,
                 sum(case when sl.dur>6944444 then 1 else 0 end) over_144hz_budget
          from slice sl join thread_track tt on sl.track_id=tt.id
          join thread t on tt.utid=t.utid join process p on t.upid=p.upid
          where sl.ts<{end} and sl.ts+sl.dur>{start} and p.name='com.miui.home'
            and (sl.name like 'GPURasterizer::Draw%' or sl.name like 'SurfaceFrame::Encode%'
                 or sl.name like 'LayerTree::Paint%' or sl.name like 'AcquireNextImageKHR%'
                 or sl.name like 'waitForBufferRelease%' or sl.name='CALLBACK_ANIMATION')
          group by stage order by max_ms desc
        """), 30)

        show("System snapshot work", analyzer.query_rows(tp, f"""
          select t.name thread,sl.name,count(*) count,
                 round(sum(sl.dur)/1e6,3) total_ms,round(max(sl.dur)/1e6,3) max_ms
          from slice sl join thread_track tt on sl.track_id=tt.id
          join thread t on tt.utid=t.utid join process p on t.upid=p.upid
          where sl.ts<{end} and sl.ts+sl.dur>{start} and p.name='system_server'
            and (t.name like 'TaskSnapshot%' or lower(sl.name) like '%snapshot%')
          group by t.utid,sl.name order by total_ms desc limit 30
        """), 30)

        show("SurfaceFlinger stages", analyzer.query_rows(tp, f"""
          select t.name thread,sl.name,count(*) count,
                 round(sum(sl.dur)/1e6,3) total_ms,round(max(sl.dur)/1e6,3) max_ms
          from slice sl join thread_track tt on sl.track_id=tt.id
          join thread t on tt.utid=t.utid join process p on t.upid=p.upid
          where sl.ts<{end} and sl.ts+sl.dur>{start}
            and p.name='/system/bin/surfaceflinger' and sl.dur>=2000000
          group by t.utid,sl.name order by total_ms desc limit 30
        """), 30)

        show("Full/Partial jank", analyzer.query_rows(tp, f"""
          select coalesce(p.name,'SurfaceFlinger') process,f.layer_name,
                 f.jank_severity_type,f.jank_type,f.gpu_composition,
                 round((f.ts-{start})/1e6,3) offset_ms,round(f.dur/1e6,3) dur_ms
          from actual_frame_timeline_slice f left join process p on f.upid=p.upid
          where f.ts<{end} and f.ts+f.dur>{start}
            and f.jank_severity_type in ('Full','Partial') order by f.ts
        """), 60)
    finally:
        tp.close()


if __name__ == "__main__":
    main()

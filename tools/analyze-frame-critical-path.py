import argparse
import importlib.util
from pathlib import Path


def load_common():
    path = Path(__file__).with_name("analyze-validated-recents.py")
    spec = importlib.util.spec_from_file_location("validated_analyzer", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def show(title, rows, limit=None):
    print(f"\n## {title}")
    selected = rows if limit is None else rows[:limit]
    if not selected:
        print("<none>")
    for row in selected:
        print(row)


def state_accounting(common, tp, item):
    start = int(item["ts"])
    end = start + int(item["dur_ns"])
    utid = int(item["utid"])
    overlap = common.overlap("st", start, end)
    return common.query_rows(tp, f"""
      select st.state,st.cpu,st.ucpu,st.blocked_function,
             round(sum({overlap})/1e6,3) ms
      from thread_state st
      where st.utid={utid} and st.ts<{end} and st.ts+st.dur>{start}
      group by st.state,st.cpu,st.ucpu,st.blocked_function order by ms desc
    """)


def runnable_competitors(common, tp, item):
    start = int(item["ts"])
    end = start + int(item["dur_ns"])
    utid = int(item["utid"])
    overlap = (
        f"max(0,min(s.ts+s.dur,w.ts+w.dur,{end})-"
        f"max(s.ts,w.ts,{start}))"
    )
    return common.query_rows(tp, f"""
      select p.name process,t.name thread,s.cpu,
             round(sum({overlap})/1e6,3) occupied_ms
      from thread_state w join sched n
        on n.utid=w.utid and n.ts between w.ts+w.dur-1000 and w.ts+w.dur+1000
      join sched s
        on s.cpu=n.cpu and s.ts<w.ts+w.dur and s.ts+s.dur>w.ts
      join thread t on s.utid=t.utid left join process p on t.upid=p.upid
      where w.utid={utid} and w.state in ('R','R+')
        and w.ts<{end} and w.ts+w.dur>{start}
        and s.ts<{end} and s.ts+s.dur>{start} and s.utid!={utid}
      group by s.utid,s.cpu order by occupied_ms desc limit 12
    """)


def nested_work(common, tp, item):
    start = int(item["ts"])
    end = start + int(item["dur_ns"])
    return common.query_rows(tp, f"""
      select sl.name,round(sl.dur/1e6,3) wall_ms,
             round(sl.thread_dur/1e6,3) cpu_ms,sl.depth
      from slice sl where sl.track_id={int(item['track_id'])}
        and sl.ts>={start} and sl.ts+sl.dur<={end} and sl.dur>=200000
      order by sl.dur desc limit 20
    """)


def running_frequencies(common, tp, item):
    start = int(item["ts"])
    end = start + int(item["dur_ns"])
    utid = int(item["utid"])
    overlap = common.overlap("s", start, end)
    return common.query_rows(tp, f"""
      select s.cpu,round(sum({overlap})/1e6,3) running_ms,
             round(sum(({overlap}) * coalesce((
               select c.value from counter c join cpu_counter_track ct
                 on c.track_id=ct.id
               where ct.name='cpufreq' and ct.cpu=s.cpu and c.ts<=s.ts
               order by c.ts desc limit 1
             ),0))/sum({overlap})/1000.0,0) weighted_mhz
      from sched s where s.utid={utid}
        and s.ts<{end} and s.ts+s.dur>{start}
      group by s.cpu order by running_ms desc
    """)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result_dir", type=Path)
    args = parser.parse_args()
    common = load_common()
    phases = common.read_phases(args.result_dir / "phases.txt")
    entry_start = phases["before_recents"]
    entry_end = phases["after_recents_command"] + 800_000_000
    tp = common.TraceProcessor(trace=str(args.result_dir / "trace.perfetto-trace"))
    try:
        frames = common.query_rows(tp, f"""
          select a.id,p.name process,a.layer_name,a.surface_frame_token,
                 a.display_frame_token,a.ts,a.dur dur_ns,
                 round((a.ts-{entry_start})/1e6,3) offset_ms,
                 round(a.dur/1e6,3) actual_ms,
                 round(e.dur/1e6,3) budget_ms,a.present_type,
                 a.jank_severity_type,a.jank_type,a.gpu_composition,
                 a.latched_fence_state
          from actual_frame_timeline_slice a join process p on a.upid=p.upid
          left join expected_frame_timeline_slice e
            on e.upid=a.upid and e.surface_frame_token=a.surface_frame_token
          where a.ts<{entry_end} and a.ts+a.dur>{entry_start}
            and p.name in ('com.miui.home','com.android.systemui',
                           'com.silverpoetry.moonlight')
          order by a.dur desc
        """)
        show("Longest app frames", frames, 30)

        jank = common.query_rows(tp, f"""
          select coalesce(p.name,'SurfaceFlinger') process,a.layer_name,
                 a.surface_frame_token,a.display_frame_token,
                 round((a.ts-{entry_start})/1e6,3) offset_ms,
                 round(a.dur/1e6,3) actual_ms,a.jank_severity_type,
                 a.jank_type,a.gpu_composition,a.latched_fence_state
          from actual_frame_timeline_slice a left join process p on a.upid=p.upid
          where a.ts<{entry_end} and a.ts+a.dur>{entry_start}
            and a.jank_severity_type in ('Full','Partial')
          order by a.ts
        """)
        show("Full and partial jank timeline", jank)

        work = common.query_rows(tp, f"""
          select sl.id,sl.track_id,t.utid,t.name thread,sl.name,sl.ts,
                 sl.dur dur_ns,round((sl.ts-{entry_start})/1e6,3) offset_ms,
                 round(sl.dur/1e6,3) wall_ms,
                 round(sl.thread_dur/1e6,3) cpu_ms
          from slice sl join thread_track tt on sl.track_id=tt.id
          join thread t on tt.utid=t.utid join process p on t.upid=p.upid
          where sl.ts<{entry_end} and sl.ts+sl.dur>{entry_start}
            and p.name='com.miui.home' and
            (sl.name='CALLBACK_ANIMATION' or
             sl.name like 'GPURasterizer::Draw%' or
             sl.name like 'SurfaceFrame::Encode%' or
             sl.name like 'LayerTree::Paint%' or
             sl.name like 'AcquireNextImageKHR%' or
             sl.name like 'waitForBufferRelease%' or
             sl.name='Canvas::DrawHyperMaterial' or
             sl.name='SurfaceFrame::Present')
          order by sl.dur desc
        """)
        show("Longest Launcher work slices", work, 40)

        selected = []
        for family in ("CALLBACK_ANIMATION", "GPURasterizer::Draw", "SurfaceFrame::Encode",
                       "Canvas::DrawHyperMaterial", "SurfaceFrame::Present"):
            selected.extend([row for row in work if row["name"].startswith(family)][:3])

        for item in selected:
            label = f"{item['thread']} {item['name']} @+{item['offset_ms']}ms"
            show(f"{label}: thread states", state_accounting(common, tp, item))
            show(f"{label}: running CPU and frequency", running_frequencies(common, tp, item))
            show(f"{label}: who occupied its runqueue", runnable_competitors(common, tp, item))
            show(f"{label}: nested work", nested_work(common, tp, item))

        system_work = common.query_rows(tp, f"""
          select p.name process,t.name thread,sl.name,
                 round((sl.ts-{entry_start})/1e6,3) offset_ms,
                 round(sl.dur/1e6,3) wall_ms,
                 round(sl.thread_dur/1e6,3) cpu_ms
          from slice sl join thread_track tt on sl.track_id=tt.id
          join thread t on tt.utid=t.utid join process p on t.upid=p.upid
          where sl.ts<{entry_end} and sl.ts+sl.dur>{entry_start}
            and ((p.name='system_server' and
                  (t.name='TaskSnapshotPer' or sl.name like '%Snapshot%'))
              or (p.name='/system/bin/surfaceflinger' and
                  (sl.name like 'composite %' or sl.name='present' or
                   sl.name like 'HwcPresentOrValidateDisplay%')))
          order by sl.dur desc limit 40
        """)
        show("System and composition work", system_work)
    finally:
        tp.close()


if __name__ == "__main__":
    main()

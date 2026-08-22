#!/usr/bin/env python3
"""Summarize Launcher CPU placement and FrameTimeline captures for tuning A/B."""

from __future__ import annotations

import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path

from perfetto.trace_processor import TraceProcessor


TARGET_THREADS = {"1.ui", "1.raster", "rt-launcher-mai", "IplrVkResMgr", "IplrVkFenceWait"}


def read_cpu_stats(case_dir: Path) -> dict:
    by_thread_cpu: dict[tuple[str, int], float] = defaultdict(float)
    with (case_dir / "simpleperf.csv").open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.reader(handle):
            if len(row) < 6 or row[5] != "task-clock" or row[0] not in TARGET_THREADS:
                continue
            by_thread_cpu[(row[0], int(row[3]))] += float(row[4].removesuffix("(ms)"))
    return by_thread_cpu


def read_frames(case_dir: Path) -> dict:
    trace = case_dir / "trace.perfetto-trace"
    processor = TraceProcessor(trace=str(trace))
    try:
        rows = list(
            processor.query(
                """
                select
                  coalesce(p.name, 'unknown') process_name,
                  a.dur / 1e6 dur_ms,
                  a.jank_severity_type severity,
                  a.jank_type jank_type
                from actual_frame_timeline_slice a
                left join process p using (upid)
                where p.name in ('com.miui.home', 'com.android.systemui', '/system/bin/surfaceflinger')
                """
            )
        )
    finally:
        processor.close()
    result: dict[str, dict] = {}
    for process_name in {row.process_name for row in rows}:
        process_rows = [row for row in rows if row.process_name == process_name]
        visible = [row for row in process_rows if row.severity in ("Full", "Partial")]
        durations = [float(row.dur_ms) for row in process_rows if row.dur_ms is not None]
        result[process_name] = {
            "frames": len(process_rows),
            "jank": len(visible),
            "max_ms": max(durations, default=0.0),
            "p95_ms": percentile(durations, 0.95),
        }
    return result


def percentile(values: list[float], quantile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    fraction = position - low
    return ordered[low] * (1.0 - fraction) + ordered[high] * fraction


def main() -> int:
    root = Path(sys.argv[1])
    cases = sorted(path for path in root.iterdir() if (path / "simpleperf.csv").exists())
    grouped: dict[str, list[tuple[dict, dict]]] = defaultdict(list)
    for case in cases:
        scenario = case.name.rsplit("-r", 1)[0]
        grouped[scenario].append((read_cpu_stats(case), read_frames(case)))

    print("scenario,thread,total_ms,prime_ms,prime_pct")
    for scenario, samples in sorted(grouped.items()):
        for thread in ("1.ui", "1.raster", "IplrVkResMgr", "IplrVkFenceWait"):
            total = sum(sum(ms for (name, _), ms in cpu.items() if name == thread) for cpu, _ in samples)
            prime = sum(cpu.get((thread, 7), 0.0) for cpu, _ in samples)
            print(f"{scenario},{thread},{total:.3f},{prime:.3f},{(100.0 * prime / total if total else 0.0):.2f}")

    print("\nscenario,process,mean_max_ms,mean_p95_ms,total_full_partial_jank")
    for scenario, samples in sorted(grouped.items()):
        process_names = sorted({name for _, frame in samples for name in frame})
        for name in process_names:
            stats = [frame[name] for _, frame in samples if name in frame]
            print(
                f"{scenario},{name},"
                f"{statistics.fmean(item['max_ms'] for item in stats):.3f},"
                f"{statistics.fmean(item['p95_ms'] for item in stats):.3f},"
                f"{sum(item['jank'] for item in stats)}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

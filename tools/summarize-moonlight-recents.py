import argparse
import importlib.util
from collections import defaultdict
from pathlib import Path
from statistics import mean


def load_analyzer(path):
    spec = importlib.util.spec_from_file_location("moonlight_analyzer", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def values_by_key(runs, phase, collection, key, value):
    output = defaultdict(list)
    for run in runs:
        for row in run["windows"][phase][collection]:
            output[row[key]].append(float(row[value]))
    return output


def combined_key(row, fields):
    return " / ".join(str(row.get(field)) for field in fields)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result_root", type=Path)
    args = parser.parse_args()
    analyzer = load_analyzer(Path(__file__).with_name("analyze-moonlight-recents.py"))
    runs = [analyzer.analyze_run(path) for path in sorted(args.result_root.glob("run-*"))]

    print(f"runs={len(runs)}")
    for phase in ("pre", "enter", "recents", "return", "post"):
        print(f"\n## {phase}")
        runtime = values_by_key(runs, phase, "process_runtime", "process", "run_ms")
        for process, samples in sorted(runtime.items(), key=lambda item: mean(item[1]), reverse=True):
            print(f"process {process}: avg={mean(samples):.3f} ms range={min(samples):.3f}-{max(samples):.3f}")
        all_runtime = defaultdict(list)
        for run in runs:
            for row in run["windows"][phase]["all_process_runtime"]:
                all_runtime[str(row["process"])].append(float(row["run_ms"]))
        print("all-system top processes:")
        for process, samples in sorted(all_runtime.items(), key=lambda item: mean(item[1]), reverse=True)[:15]:
            print(f"  {process}: avg={mean(samples):.3f} ms")

        moonlight_total = []
        moonlight_perf = []
        for run in runs:
            per_cpu = run["windows"][phase]["moonlight_by_cpu"]
            total = sum(float(row["run_ms"]) for row in per_cpu)
            perf = sum(float(row["run_ms"]) for row in per_cpu if int(row["cpu"]) >= 3)
            moonlight_total.append(total)
            moonlight_perf.append(perf)
        print(f"Moonlight CPU3-7 share: avg={mean(moonlight_perf):.3f}/{mean(moonlight_total):.3f} ms ({mean(moonlight_perf)/max(mean(moonlight_total),0.001)*100:.1f}%)")

        thread_runtime = defaultdict(list)
        runnable_total = defaultdict(list)
        runnable_max = defaultdict(list)
        for run in runs:
            for row in run["windows"][phase]["top_threads"]:
                key = combined_key(row, ("process", "thread"))
                thread_runtime[key].append(float(row["run_ms"]))
            for row in run["windows"][phase]["runnable"]:
                key = combined_key(row, ("process", "thread"))
                runnable_total[key].append(float(row["runnable_ms"]))
                runnable_max[key].append(float(row["max_runnable_ms"]))
        print("top thread runtime:")
        for key, samples in sorted(thread_runtime.items(), key=lambda item: mean(item[1]), reverse=True)[:12]:
            print(f"  {key}: avg={mean(samples):.3f} ms")
        print("top runnable delay:")
        for key, samples in sorted(runnable_total.items(), key=lambda item: mean(item[1]), reverse=True)[:12]:
            print(f"  {key}: total_avg={mean(samples):.3f} ms max_wait={max(runnable_max[key]):.3f} ms")

        jank = defaultdict(int)
        for run in runs:
            for row in run["windows"][phase]["jank"]:
                key = combined_key(row, ("process", "jank_type", "jank_severity_type"))
                jank[key] += 1
        print("jank totals:")
        for key, count in sorted(jank.items(), key=lambda item: item[1], reverse=True):
            print(f"  {count}x {key}")
        if not jank:
            print("  none")

        long_slices = defaultdict(list)
        for run in runs:
            for row in run["windows"][phase]["long_slices"]:
                key = combined_key(row, ("process", "thread", "name"))
                long_slices[key].append(float(row["max_ms"]))
        print("largest slices:")
        for key, samples in sorted(long_slices.items(), key=lambda item: max(item[1]), reverse=True)[:12]:
            print(f"  {key}: observed_max={max(samples):.3f} ms avg_of_present={mean(samples):.3f} ms")

    print("\n## core saturation")
    for run in runs:
        bins = defaultdict(int)
        for row in run["cpu_busy_20ms"]:
            bins[int(row["bin_ms"])] += 1
        total_bins = max(1, int((run["windows"]["return"]["end"] - run["windows"]["enter"]["start"]) / 20_000_000))
        print(
            f"{run['run']}: >=4 cores {sum(value >= 4 for value in bins.values())}/{total_bins}, "
            f">=6 cores {sum(value >= 6 for value in bins.values())}/{total_bins}, "
            f"all 8 {sum(value >= 8 for value in bins.values())}/{total_bins}, max={max(bins.values(), default=0)}"
        )
    for phase in ("enter", "recents", "return"):
        print(f"{phase}:")
        for run in runs:
            values = run["windows"][phase]["core_saturation"]
            print(
                f"  {run['run']}: >=4 {values['ge4']}/{values['total_bins']}, "
                f">=6 {values['ge6']}/{values['total_bins']}, all8 {values['all8']}/{values['total_bins']}, max={values['max']}"
            )

    print("\n## cpu frequency")
    by_cpu = defaultdict(list)
    for run in runs:
        for row in run["cpu_frequency"]:
            by_cpu[int(row["cpu"])].append(row)
    for cpu, samples in sorted(by_cpu.items()):
        print(
            f"CPU{cpu}: min={min(int(row['min_khz']) for row in samples)} "
            f"avg={mean(float(row['avg_khz']) for row in samples):.0f} "
            f"max={max(int(row['max_khz']) for row in samples)} kHz"
        )


if __name__ == "__main__":
    main()

import argparse
import sys
from pathlib import Path

PERFETTO_SITE = Path(r"D:\Projects\HyperOS4-Sheng-DSU\tools\perfetto-python")
if PERFETTO_SITE.exists():
    sys.path.insert(0, str(PERFETTO_SITE))

from perfetto.trace_processor import TraceProcessor


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("tables", nargs="+")
    args = parser.parse_args()
    tp = TraceProcessor(trace=str(args.trace))
    try:
        for table in args.tables:
            print(f"\n[{table}]")
            for row in tp.query(f"pragma table_info({table})"):
                print(row)
    finally:
        tp.close()


if __name__ == "__main__":
    main()

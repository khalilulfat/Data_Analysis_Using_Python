"""Execute every notebook in order (used locally and by GitHub Actions).

    python scripts/run_all_notebooks.py           # run and save outputs back into the notebooks
    python scripts/run_all_notebooks.py --check   # run without modifying files (CI mode)
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import nbformat
from nbconvert.preprocessors import CellExecutionError, ExecutePreprocessor

NOTEBOOKS = Path(__file__).resolve().parents[1] / "notebooks"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="execute only, do not write outputs")
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()

    failed = []
    for path in sorted(NOTEBOOKS.glob("[0-9][0-9]_*.ipynb")):
        start = time.time()
        nb = nbformat.read(path, as_version=4)
        ep = ExecutePreprocessor(timeout=args.timeout, kernel_name="python3")
        try:
            ep.preprocess(nb, {"metadata": {"path": str(NOTEBOOKS)}})
            if not args.check:
                nbformat.write(nb, path)
            print(f"OK    {path.name}  ({time.time() - start:.0f}s)")
        except CellExecutionError as err:
            failed.append(path.name)
            print(f"FAIL  {path.name}\n{str(err)[:2000]}")
    if failed:
        print("\nFailed:", ", ".join(failed))
        return 1
    print("\nAll notebooks executed successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

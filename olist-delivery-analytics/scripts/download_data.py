"""Download the Olist dataset from Kaggle into data/raw/ as .csv.gz files.

Usage:  pip install kagglehub  &&  python scripts/download_data.py
"""
from __future__ import annotations

import gzip
import shutil
import sys
from pathlib import Path

RAW = Path(__file__).resolve().parents[1] / "data" / "raw"
DATASET = "olistbr/brazilian-ecommerce"


def main() -> int:
    try:
        import kagglehub
    except ImportError:
        print("kagglehub is not installed. Run:  pip install kagglehub\n"
              f"Or download https://www.kaggle.com/datasets/{DATASET} manually and extract the CSVs into {RAW}")
        return 1

    src = Path(kagglehub.dataset_download(DATASET))
    RAW.mkdir(parents=True, exist_ok=True)
    csvs = sorted(src.rglob("*.csv"))
    if not csvs:
        print(f"No CSV files found in {src}")
        return 1
    for csv in csvs:
        target = RAW / f"{csv.name}.gz"
        with csv.open("rb") as fin, gzip.open(target, "wb", compresslevel=9) as fout:
            shutil.copyfileobj(fin, fout)
        print(f"saved {target.relative_to(RAW.parents[1])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
m1_to_kdb.py

Bulk-load one exchange's per-symbol Parquet (from m1_backfill.py) into the
kdb+ date-partitioned table eq_m1_yfinance under an HDB root
(default C:/data/db1/eq): streams every <SYMBOL>.parquet into one staging CSV
tagged with the exchange, then hands it to load_eq_m1_yfinance.q.
Idempotent per date.

Deps: pandas, pyarrow ; needs q + a kdb+ licence (QHOME).
Usage:
  python m1_to_kdb.py --exchange hkex
  python m1_to_kdb.py --exchange nyse --db C:/data/db1/eq --keep-stage
  python m1_to_kdb.py --exchange hkex --no-load          # build staging CSV only
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import pandas as pd

import exchanges
from m1_common import now_hms

HERE = Path(__file__).resolve().parent
LOADER_Q = HERE / "load_eq_m1_yfinance.q"
OUT_COLS = ["barTime", "sym", "open", "high", "low", "close", "volume", "exchange"]


def stream_dir(hist_dir: Path, csv_path: Path, exchange: str) -> tuple[int, int]:
    files = sorted(hist_dir.glob("*.parquet"))
    if not files:
        sys.exit(f"no Parquet files in {hist_dir} - run:  python m1_backfill.py --exchange {exchange}")
    rows = 0
    header = True
    for i, f in enumerate(files, 1):
        df = pd.read_parquet(f, columns=["barTime", "open", "high", "low", "close", "volume"])
        if df.empty:
            continue
        df["barTime"] = pd.to_datetime(df["barTime"])
        df = df.dropna(subset=["close"])
        if df.empty:
            continue
        df["sym"] = f.stem
        df["volume"] = df["volume"].fillna(0).round().astype("int64")
        for c in ("open", "high", "low", "close"):
            df[c] = df[c].astype("float64")
        df["exchange"] = exchange
        df["barTime"] = df["barTime"].dt.strftime("%Y-%m-%dT%H:%M:%S")
        df[OUT_COLS].to_csv(csv_path, mode="w" if header else "a", header=header, index=False)
        header = False
        rows += len(df)
        if i % 500 == 0 or i == len(files):
            print(f"[{now_hms()}] {i}/{len(files)} files, {rows:,} rows")
    return len(files), rows


def run_loader(csv_path: Path, args, table: str) -> None:
    qexe = Path(args.q) if args.q else _default_q(args.qhome)
    if not qexe.exists():
        sys.exit(f"q not found: {qexe} (pass --q / --qhome)")
    env = dict(os.environ, QHOME=args.qhome)
    cmd = [str(qexe), str(LOADER_Q), "-stage", str(csv_path), "-db", args.db, "-table", table]
    print(f"[{now_hms()}] loading -> {args.db}\n  {' '.join(cmd)}")
    r = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL)
    if r.returncode != 0:
        sys.exit(f"q loader failed (exit {r.returncode})")


def _default_q(qhome: str) -> Path:
    exe = "q.exe" if os.name == "nt" else "q"
    arch = "w64" if os.name == "nt" else ("l64" if sys.platform.startswith("linux") else "m64")
    return Path(qhome) / arch / exe


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Bulk-load one exchange's m1 backfill Parquet into kdb+")
    p.add_argument("--exchange", required=True, choices=exchanges.keys())
    p.add_argument("--hist-dir", default=None, help="default: hist/<key> beside this script")
    p.add_argument("--db", default="C:/data/db1/eq")
    p.add_argument("--stage-dir", default=str(HERE / ".stage"),
                   help="staging CSV dir (must NOT be inside the HDB root)")
    p.add_argument("--q", default=None)
    p.add_argument("--qhome", default=os.environ.get("QHOME", "C:/q"))
    p.add_argument("--no-load", action="store_true")
    p.add_argument("--keep-stage", action="store_true")
    return p.parse_args(argv)


def main(argv=None) -> None:
    args = parse_args(argv)
    spec = exchanges.get(args.exchange)
    hist_dir = Path(args.hist_dir) if args.hist_dir else HERE / "hist" / spec.key
    stage_dir = Path(args.stage_dir)
    stage_dir.mkdir(parents=True, exist_ok=True)
    csv_path = stage_dir / f"eq_m1_yfinance_{spec.key}_{datetime.now():%Y%m%d_%H%M%S}.csv"

    files, rows = stream_dir(hist_dir, csv_path, spec.key)
    mb = csv_path.stat().st_size / 1e6
    print(f"[{now_hms()}] staged {rows:,} rows from {files} files ({mb:.0f} MB) "
          f"-> {csv_path}  (table {spec.table})")

    if args.no_load:
        return
    run_loader(csv_path, args, spec.table)
    if not args.keep_stage:
        csv_path.unlink(missing_ok=True)
    print(f"[{now_hms()}] done")


if __name__ == "__main__":
    main()

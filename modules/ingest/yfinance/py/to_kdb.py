#!/usr/bin/env python3
"""
to_kdb.py - bulk-load one --exchange's per-symbol Parquet (from backfill.py)
into its kdb+ date-partitioned table: streams every <SYMBOL>.parquet into
one staging CSV tagged with the `exchange, then runs the cadence's .q
loader. Replaces m1_to_kdb.py + d1_to_kdb.py. Idempotent per date.

  --cadence m1 -> spec.table              (eq_m1_yfinance / futures_m1_yfinance / rateIndices_m1_yfinance)
  --cadence d1 -> spec.table _m1_->_d1_   (eq_d1_yfinance / futures_d1_yfinance / rateIndices_d1_yfinance)

--db defaults to C:/data/db1/eq. Pass --db explicitly for the three table
pairs that live in their own dedicated root (all migrated 2026-09-05, see
schema_yfinance.q): rateIndices_m1_yfinance/rateIndices_d1_yfinance share
C:/data/db1/rates; futures_m1_yfinance/futures_d1_yfinance share
C:/data/db1/futures; fx_m1_yfinance/fx_d1_yfinance share C:/data/db1/efx
(the read-only vendor FX archive's root - a deliberate, knowingly-made
exception to that archive's usual "openQ never writes here" rule; the
first real load there pays a one-time .Q.chk stub pass across its ~5,375
partitions).

Deps: pandas, pyarrow ; needs q + a kdb+ licence (QHOME).
Usage:
  python to_kdb.py --exchange hkex    --cadence m1
  python to_kdb.py --exchange rateidx --cadence d1 --db C:/data/db1/rates
  python to_kdb.py --exchange futures --cadence m1 --db C:/data/db1/futures
  python to_kdb.py --exchange fx      --cadence m1 --db C:/data/db1/efx
  python to_kdb.py --exchange nyse    --cadence m1 --no-load     # staging CSV only
"""

from __future__ import annotations

import argparse
import os
from datetime import datetime
from pathlib import Path

import exchanges
from core import MODULE_DIR, cadence, now_hms
from kdb import run_loader, stream_parquet_dir


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Bulk-load one --exchange's backfill Parquet into kdb+")
    p.add_argument("--exchange", required=True, choices=exchanges.keys())
    p.add_argument("--cadence", required=True, choices=("m1", "d1"))
    p.add_argument("--hist-dir", default=None, help="default: hist[/_d1]/<key> under the module root")
    p.add_argument("--db", default="C:/data/db1/eq")
    p.add_argument("--stage-dir", default=str(MODULE_DIR / ".stage"),
                   help="staging CSV dir (must NOT be inside the HDB root)")
    p.add_argument("--q", default=None)
    p.add_argument("--qhome", default=os.environ.get("QHOME", "C:/q"))
    p.add_argument("--schema", default=None,
                   help="table-shape source for load_yfinance.q (default: openQ/schemas/schema_yfinance.q)")
    p.add_argument("--no-load", action="store_true")
    p.add_argument("--keep-stage", action="store_true")
    return p.parse_args(argv)


def main(argv=None) -> None:
    args = parse_args(argv)
    cad = cadence(args.cadence)
    spec = exchanges.get(args.exchange)
    table = cad.table_for(spec.table)
    hist_dir = Path(args.hist_dir) if args.hist_dir else MODULE_DIR / cad.hist_subdir / spec.key
    stage_dir = Path(args.stage_dir)
    stage_dir.mkdir(parents=True, exist_ok=True)
    csv_path = stage_dir / f"{table}_{spec.key}_{datetime.now():%Y%m%d_%H%M%S}.csv"

    files, rows = stream_parquet_dir(hist_dir, csv_path, cad, spec.key)
    mb = csv_path.stat().st_size / 1e6
    print(f"[{now_hms()}] staged {rows:,} rows from {files} files ({mb:.0f} MB) "
          f"-> {csv_path}  (table {table})")

    if args.no_load:
        return
    run_loader(csv_path, cad, db=args.db, table=table, q=args.q, qhome=args.qhome,
               schema=args.schema)
    if not args.keep_stage:
        csv_path.unlink(missing_ok=True)
    print(f"[{now_hms()}] done")


if __name__ == "__main__":
    main()

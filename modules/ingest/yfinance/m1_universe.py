#!/usr/bin/env python3
"""
m1_universe.py

Build a cash-equity universe for one exchange and write it as
exchanges/<key>_tickers.csv (columns: ticker, code, name, ...) for m1_backfill.py and
m1_feed.py to consume. Everything exchange-specific lives in exchanges.py.

Deps: pandas (+ openpyxl for hkex)
Usage:
  python m1_universe.py --exchange hkex                 # -> exchanges/hkex_tickers.csv
  python m1_universe.py --exchange hkex --include-reits
  python m1_universe.py --exchange nyse                 # -> exchanges/nyse_tickers.csv
  python m1_universe.py --exchange nasdaq --include-etfs
  python m1_universe.py --exchange lse --universe-file lse_instruments.csv
"""

from __future__ import annotations

import argparse
from pathlib import Path

import exchanges
from m1_common import now_hms

HERE = Path(__file__).resolve().parent


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Build a per-exchange cash-equity universe -> exchanges/<key>_tickers.csv")
    p.add_argument("--exchange", required=True, choices=exchanges.keys())
    p.add_argument("--out", default=None, help="output CSV (default: exchanges/<key>_tickers.csv)")
    # exchange-specific knobs (ignored by exchanges that don't use them)
    p.add_argument("--url", default=None, help="hkex: override the List of Securities .xlsx URL")
    p.add_argument("--include-reits", action="store_true", help="hkex: also keep REITs")
    p.add_argument("--include-trust", action="store_true", help="hkex: also keep Trusts")
    p.add_argument("--include-etp", action="store_true", help="hkex: also keep ETPs")
    p.add_argument("--include-etfs", action="store_true", help="nyse/nasdaq: also keep ETFs")
    p.add_argument("--universe-file", default=None, help="lse: CSV with a code/TIDM column")
    return p.parse_args(argv)


def main(argv=None) -> None:
    args = parse_args(argv)
    spec = exchanges.get(args.exchange)
    out = Path(args.out) if args.out else HERE / spec.tickers_filename()

    print(f"[{now_hms()}] building {spec.name} universe")
    df = spec.build_universe(args)
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(out, index=False)
    print(f"[{now_hms()}] {len(df)} securities -> {out}")
    print(df.head(8).to_string(index=False))


if __name__ == "__main__":
    main()

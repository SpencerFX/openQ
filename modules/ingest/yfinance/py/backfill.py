#!/usr/bin/env python3
"""
backfill.py - historical OHLCV backfill for one --exchange's universe from
Yahoo Finance. One Parquet file per symbol under hist[/_d1]/<key>/, merged
and de-duplicated on re-run. Replaces m1_backfill.py + d1_backfill.py.

  --cadence m1   1-minute bars. Yahoo keeps ~30 days of 1m history and
                 serves <=8 days per request, so this pages backwards in
                 <=7-day windows (--days, capped at 30). Run it daily to
                 keep accumulating minutes Yahoo will later drop.
  --cadence d1   daily bars. One period=max request per batch (decades of
                 history), or --start[/--end] for a bounded span.

barTime is UTC / tz-stripped, date is the tz-stripped calendar day - see
core.normalise / eod_housekeeping.q.

Deps: yfinance, pandas, pyarrow
Usage:
  python backfill.py --exchange hkex   --cadence m1 --days 30 --resume
  python backfill.py --exchange nyse   --cadence m1 --max-symbols 50
  python backfill.py --exchange rateidx --cadence d1
  python backfill.py --exchange futures --cadence d1 --start 2010-01-01
"""

from __future__ import annotations

import argparse
from pathlib import Path

import exchanges
from core import (
    MAX_LOOKBACK_DAYS, MODULE_DIR, cadence, fetch_history, load_tickers, merge_write, now_hms,
)


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Yahoo OHLCV backfill for one --exchange's universe")
    p.add_argument("--exchange", required=True, choices=exchanges.keys())
    p.add_argument("--cadence", required=True, choices=("m1", "d1"))
    p.add_argument("--tickers", default=None, help="default: exchanges/<key>_tickers.csv")
    p.add_argument("--out-dir", default=None, help="default: hist[/_d1]/<key> under the module root")
    p.add_argument("--days", type=int, default=MAX_LOOKBACK_DAYS,
                   help=f"m1 lookback, capped at {MAX_LOOKBACK_DAYS}")
    p.add_argument("--start", default=None, help="d1 first date YYYY-MM-DD (default: period=max)")
    p.add_argument("--end", default=None, help="d1 last date YYYY-MM-DD, exclusive")
    p.add_argument("--batch-size", type=int, default=40)
    p.add_argument("--max-symbols", type=int, default=0)
    p.add_argument("--resume", action="store_true", help="skip symbols whose Parquet already exists")
    p.add_argument("--sleep", type=float, default=1.5, help="pause between batches")
    return p.parse_args(argv)


def main(argv=None) -> None:
    args = parse_args(argv)
    cad = cadence(args.cadence)
    spec = exchanges.get(args.exchange)
    tickers_path = Path(args.tickers) if args.tickers else MODULE_DIR / spec.tickers_filename()
    out_dir = Path(args.out_dir) if args.out_dir else MODULE_DIR / cad.hist_subdir / spec.key
    out_dir.mkdir(parents=True, exist_ok=True)

    symbols = load_tickers(tickers_path, args.max_symbols)
    if args.resume:
        symbols = [s for s in symbols if not (out_dir / f"{s}.parquet").exists()]
    span = (("from " + args.start) if args.start else "period=max") if cad.name == "d1" \
        else f"{min(args.days, MAX_LOOKBACK_DAYS)}d"
    print(f"[{now_hms()}] {spec.key}/{cad.name}: {len(symbols)} symbols "
          f"({span}, {spec.tz}) -> {out_dir}")
    if not symbols:
        print(f"[{now_hms()}] nothing to do")
        return

    hist = fetch_history(symbols, cad, days=args.days, start=args.start, end=args.end,
                         batch_size=args.batch_size, sleep=args.sleep)
    total = got = 0
    for sym, frame in hist.items():
        n = merge_write(out_dir / f"{sym}.parquet", frame, cad)
        total += n
        got += bool(n)
    print(f"[{now_hms()}] wrote {total:,} bar-rows across {got} symbols -> {out_dir}")


if __name__ == "__main__":
    main()

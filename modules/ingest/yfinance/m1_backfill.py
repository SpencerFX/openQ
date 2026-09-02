#!/usr/bin/env python3
"""
m1_backfill.py

Historical 1-minute OHLCV backfill for one exchange's cash-equity universe
from Yahoo Finance. One Parquet file per symbol (barTime,open,high,low,close,
volume) under <out-dir>, merged/de-duplicated on re-run.

Yahoo serves ~30 calendar days of 1m history and <=8 days per request, so this
pages backwards in <=7-day windows. Run it daily to keep accumulating minutes
Yahoo will later drop. barTime is UTC, tz stripped - matching
load_eq_m1_yfinance.q / m1_feed.py (see m1_common.normalise_bars).

Deps: yfinance, pandas, pyarrow
Usage:
  python m1_backfill.py --exchange hkex                       # last 30d
  python m1_backfill.py --exchange hkex --days 7 --resume
  python m1_backfill.py --exchange nyse --max-symbols 50
"""

from __future__ import annotations

import argparse
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd

try:
    import yfinance as yf
except ImportError:
    sys.exit("yfinance is not installed.  pip install yfinance pandas pyarrow")

import exchanges
from m1_common import BAR_COLS, chunked, load_tickers, normalise_bars, now_hms, split_batch

HERE = Path(__file__).resolve().parent
WINDOW_DAYS = 7          # <= Yahoo's per-request 1m cap (8d); 7 leaves headroom
MAX_LOOKBACK_DAYS = 30   # Yahoo keeps ~30d of 1m history


def windows(days: int):
    days = min(days, MAX_LOOKBACK_DAYS)
    end = datetime.now(timezone.utc).date() + timedelta(days=1)
    remaining = days
    while remaining > 0:
        step = min(WINDOW_DAYS, remaining)
        start = end - timedelta(days=step)
        yield start.isoformat(), end.isoformat()
        end = start
        remaining -= step


def merge_write(path: Path, fresh: pd.DataFrame) -> int:
    if fresh.empty:
        return 0
    if path.exists():
        try:
            fresh = pd.concat([pd.read_parquet(path), fresh], ignore_index=True)
        except Exception:  # noqa: BLE001
            pass
    fresh["barTime"] = pd.to_datetime(fresh["barTime"])
    fresh = (
        fresh.drop_duplicates(subset="barTime", keep="last")
        .sort_values("barTime")
        .reset_index(drop=True)[BAR_COLS]
    )
    fresh.to_parquet(path, engine="pyarrow", index=False)
    return len(fresh)


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Yahoo 1m OHLCV backfill for one exchange's equities")
    p.add_argument("--exchange", required=True, choices=exchanges.keys())
    p.add_argument("--tickers", default=None, help="default: exchanges/<key>_tickers.csv")
    p.add_argument("--out-dir", default=None, help="default: hist/<key> beside this script")
    p.add_argument("--days", type=int, default=MAX_LOOKBACK_DAYS, help=f"lookback (capped at {MAX_LOOKBACK_DAYS})")
    p.add_argument("--batch-size", type=int, default=40)
    p.add_argument("--max-symbols", type=int, default=0)
    p.add_argument("--resume", action="store_true", help="skip symbols whose Parquet already exists")
    p.add_argument("--sleep", type=float, default=1.5, help="pause between batches")
    return p.parse_args(argv)


def main(argv=None) -> None:
    args = parse_args(argv)
    spec = exchanges.get(args.exchange)
    tickers_path = Path(args.tickers) if args.tickers else HERE / spec.tickers_filename()
    out_dir = Path(args.out_dir) if args.out_dir else HERE / "hist" / spec.key
    out_dir.mkdir(parents=True, exist_ok=True)

    symbols = load_tickers(tickers_path, args.max_symbols)
    if args.resume:
        symbols = [s for s in symbols if not (out_dir / f"{s}.parquet").exists()]
    wins = list(windows(args.days))
    print(f"[{now_hms()}] {spec.key}: {len(symbols)} symbols x {len(wins)} window(s) "
          f"({spec.tz}) -> {out_dir}")

    per_symbol: dict[str, list[pd.DataFrame]] = {s: [] for s in symbols}
    for wi, (start, end) in enumerate(wins, 1):
        for bi, batch in enumerate(chunked(symbols, args.batch_size), 1):
            try:
                data = yf.download(
                    tickers=batch, start=start, end=end, interval="1m",
                    group_by="ticker", auto_adjust=False, actions=False,
                    threads=True, progress=False,
                )
            except Exception as exc:  # noqa: BLE001
                print(f"[{now_hms()}] win {wi} batch {bi}: {exc}")
                continue
            if data is None or data.empty:
                continue
            parts = split_batch(data, batch)
            for s in batch:
                f = normalise_bars(parts.get(s))
                if not f.empty:
                    per_symbol[s].append(f)
            if args.sleep:
                time.sleep(args.sleep)
        print(f"[{now_hms()}] window {wi}/{len(wins)} {start}..{end} done")

    total = got = 0
    for s, frames in per_symbol.items():
        if not frames:
            continue
        total += merge_write(out_dir / f"{s}.parquet", pd.concat(frames, ignore_index=True))
        got += 1
    print(f"[{now_hms()}] wrote {total:,} bar-rows across {got} symbols -> {out_dir}")


if __name__ == "__main__":
    main()

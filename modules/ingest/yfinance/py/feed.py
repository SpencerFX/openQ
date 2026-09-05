#!/usr/bin/env python3
"""
feed.py - live 1-minute OHLCV feed handler for one --exchange's universe:
polls Yahoo Finance over exchanges/<key>_tickers.csv and, once a minute bar
is complete, streams it on. All exchange-specific facts (timezone, session
window, the `exchange symbol, the target table) come from exchanges.py.
Replaces m1_feed.py.

Two clocks, deliberately: the exchange-LOCAL tz (exchanges.py
poll_start/poll_end, in_session()) governs when this process polls at all -
a wall-clock question. The stored barTime is UTC / tz-stripped
(core.normalise), matching every other date decision in this repo, so
"today"'s partition means the same UTC day everywhere.

Two sinks (--sink), both in kdb.py:
  csv   append completed bars to <csv-dir>/<table>_<key>_YYYYMMDD.csv -
        exactly what load_yfinance.q ingests. No tickerplant.
  tp    openQ tickerplant: qpython handle, `upd` in schema order (minus
        the leading `timestamp, which core/tp.q's .u.updB prepends).

Only bars strictly before the current minute are emitted, each
(sym, minute) at most once per process (tracked in last_pub).

Yahoo quotes are delayed (~15 min for HK) and its 1m bars are best-effort -
a delayed-bar collector, not a real-time feed. Swap core.fetch_today() for
a broker/vendor source for true real time; the sinks and bar-completion
logic are source-agnostic.

Deps: yfinance, pandas  (+ qpython, numpy for --sink tp)
Usage:
  python feed.py --exchange hkex --sink csv --csv-dir live
  python feed.py --exchange nyse --sink tp --host localhost --port 5060
Env fallbacks (CLI wins): M1_FEED_HOST, M1_FEED_PORT, M1_FEED_INTERVAL, M1_FEED_TICKERS
"""

from __future__ import annotations

import argparse
import logging
import os
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd

import exchanges
from core import MODULE_DIR, fetch_today, load_tickers
from kdb import make_sink

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
log = logging.getLogger("feed")


def in_session(now_local: datetime, spec: exchanges.ExchangeSpec, enforce: bool) -> bool:
    if not enforce:
        return True
    if now_local.weekday() >= 5:
        return False
    start, end = spec.poll_window()
    return start <= now_local.time() <= end


def completed_new(bars: pd.DataFrame, last_pub: dict) -> pd.DataFrame:
    """bars.barTime is naive UTC (core.normalise) - so the cutoff must be
    too, whatever exchange-local tz governs this process's session gating.
    Keep only bars strictly before the current minute and newer than the
    last one already emitted for that symbol."""
    if bars.empty:
        return bars
    cutoff = pd.Timestamp(datetime.now(timezone.utc).replace(tzinfo=None)).floor("min")
    bars = bars[bars["barTime"] < cutoff]
    if bars.empty:
        return bars
    keep = bars["barTime"] > bars["sym"].map(lambda s: last_pub.get(s, pd.Timestamp.min))
    return bars[keep].sort_values(["barTime", "sym"]).reset_index(drop=True)


def run(sink, tickers, spec, tzinfo, interval, batch_size, enforce_session, once=False):
    last_pub: dict[str, pd.Timestamp] = {}
    it = 0
    while True:
        it += 1
        now_local = datetime.now(tzinfo)
        if not in_session(now_local, spec, enforce_session):
            log.info("iter %d: outside %s session (%s) - idling",
                     it, spec.key, now_local.strftime("%a %H:%M %Z"))
        else:
            fresh = completed_new(fetch_today(tickers, batch_size, log), last_pub)
            if len(fresh):
                sink.write(fresh)
                for s, g in fresh.groupby("sym"):
                    last_pub[s] = g["barTime"].max()
                log.info("iter %d: emitted %d bar(s) across %d symbol(s), latest %s",
                         it, len(fresh), fresh["sym"].nunique(), fresh["barTime"].max())
            else:
                log.info("iter %d: no new completed bars", it)
        if once:
            return
        nxt = (datetime.now() + timedelta(seconds=interval)).replace(microsecond=0)
        time.sleep(max(2.0, (nxt - datetime.now()).total_seconds()))


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Live 1m OHLCV feed handler for one --exchange's universe")
    p.add_argument("--exchange", required=True, choices=exchanges.keys())
    p.add_argument("--tickers", default=os.environ.get("M1_FEED_TICKERS"),
                   help="default: exchanges/<key>_tickers.csv")
    p.add_argument("--sink", choices=("csv", "tp"), default="csv")
    p.add_argument("--csv-dir", default=str(MODULE_DIR / "live"))
    p.add_argument("--host", default=os.environ.get("M1_FEED_HOST", "localhost"))
    p.add_argument("--port", type=int, default=int(os.environ.get("M1_FEED_PORT", "5060")))
    p.add_argument("--interval", type=int, default=int(os.environ.get("M1_FEED_INTERVAL", "60")))
    p.add_argument("--batch-size", type=int, default=40)
    p.add_argument("--no-session", action="store_true", help="poll regardless of trading hours")
    p.add_argument("--once", action="store_true", help="one poll then exit (smoke test)")
    return p.parse_args(argv)


def main(argv=None) -> None:
    args = parse_args(argv)
    spec = exchanges.get(args.exchange)
    tzinfo = ZoneInfo(spec.tz)
    tickers_path = Path(args.tickers) if args.tickers else MODULE_DIR / spec.tickers_filename()
    tickers = load_tickers(tickers_path)
    log.info("loaded %d %s tickers from %s", len(tickers), spec.key, tickers_path)

    sink = make_sink(args.sink, csv_dir=Path(args.csv_dir), host=args.host, port=args.port,
                     exchange=spec.key, table=spec.table)
    try:
        run(sink, tickers, spec, tzinfo, args.interval, args.batch_size,
            not args.no_session, once=args.once)
    except KeyboardInterrupt:
        log.info("shutting down")
    finally:
        sink.close()


if __name__ == "__main__":
    main()

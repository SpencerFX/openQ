#!/usr/bin/env python3
"""
modules/ingest/yfinance/m1_feed.py

Live feed handler for one exchange's cash equities: polls Yahoo Finance for
1-minute OHLCV bars over exchanges/<key>_tickers.csv and, once a minute bar is complete,
streams it on. All exchange-specific facts (timezone, session window, the
`exchange symbol) come from exchanges.py via --exchange.

Two different clocks are in play, deliberately: the exchange-LOCAL tz
(exchanges.py's poll_start/poll_end, in_session()) governs when this
process polls at all - a local-wall-clock question. The stored barTime
itself is UTC (m1_common.normalise_bars), matching every other date/time
decision in this repo (kdb+'s `.z.d`, the HDB's date partitioning,
eod_housekeeping.q's EOD trigger) - so "today"'s partition means the same
UTC calendar day everywhere, with no local/UTC date reconciliation needed.

Two sinks (pick with --sink):
  tp   - openQ tickerplant. Opens a qpython handle and calls `upd` with
         column-oriented data in schemas/schema_eq_m1_yfinance.q order
         (minus the leading `timestamp, which core/tp.q's .u.updB prepends
         as the arrival stamp). Same wiring as yahoo_finance_streamer.py.
  csv  - append completed bars to
         <dir>/eq_m1_yfinance_<key>_YYYYMMDD.csv with columns
         barTime,sym,open,high,low,close,volume,exchange - exactly what
         load_eq_m1_yfinance.q ingests. No tickerplant / no qpython.

Only bars with barTime strictly before the current minute are emitted, and
each (sym,minute) at most once per process (tracked in `last_pub`).

Yahoo quotes are delayed (~15 min for HK) and its 1m bars are best-effort -
this is a delayed-bar collector, not a real-time market-data feed. Swap in a
broker/vendor source behind fetch_bars() for true real time; the sinks and
bar-completion logic stay the same.

Deps: yfinance, pandas  (+ qpython, numpy for --sink tp)
Usage:
  python m1_feed.py --exchange hkex --sink csv --csv-dir live
  python m1_feed.py --exchange nyse --sink tp --host localhost --port 5060
Env fallbacks (CLI wins): M1_FEED_HOST, M1_FEED_PORT, M1_FEED_INTERVAL, M1_FEED_TICKERS
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd

try:
    import yfinance as yf
except ImportError:
    sys.exit("yfinance is not installed.  pip install yfinance pandas")

import exchanges
from m1_common import chunked, load_tickers, normalise_bars

HERE = Path(__file__).resolve().parent

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
log = logging.getLogger("m1_feed")

# column order after `timestamp - must match schemas/schema_eq_m1_yfinance.q
CSV_HEADER = ["barTime", "sym", "open", "high", "low", "close", "volume", "exchange"]


# --------------------------------------------------------------------------- #
# session                                                                    #
# --------------------------------------------------------------------------- #
def in_session(now_local: datetime, spec: exchanges.ExchangeSpec, enforce: bool) -> bool:
    if not enforce:
        return True
    if now_local.weekday() >= 5:
        return False
    start, end = spec.poll_window()
    return start <= now_local.time() <= end


# --------------------------------------------------------------------------- #
# fetch + bar completion                                                     #
# --------------------------------------------------------------------------- #
def fetch_bars(tickers: list[str], batch_size: int) -> pd.DataFrame:
    """Today's 1m bars for the universe as [sym, barTime(naive UTC), o,h,l,c,volume]."""
    frames = []
    for batch in chunked(tickers, batch_size):
        try:
            data = yf.download(
                tickers=batch, period="1d", interval="1m", group_by="ticker",
                auto_adjust=False, actions=False, threads=True, progress=False,
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("batch fetch failed (%d syms): %s", len(batch), exc)
            continue
        if data is None or data.empty:
            continue
        multi = isinstance(data.columns, pd.MultiIndex)
        present = set(data.columns.get_level_values(0)) if multi else set(batch[:1])
        for s in batch:
            if multi and s not in present:
                continue
            f = normalise_bars(data[s] if multi else data, sym=s)
            if not f.empty:
                frames.append(f)
    if not frames:
        return pd.DataFrame(columns=["sym", "barTime", "open", "high", "low", "close", "volume"])
    return pd.concat(frames, ignore_index=True)


def completed_new(bars: pd.DataFrame, last_pub: dict) -> pd.DataFrame:
    """bars.barTime is naive UTC (see m1_common.normalise_bars) - the cutoff
    must be too, regardless of which exchange-local tzinfo governs this
    process's session gating."""
    if bars.empty:
        return bars
    cutoff = pd.Timestamp(datetime.now(timezone.utc).replace(tzinfo=None)).floor("min")
    bars = bars[bars["barTime"] < cutoff]
    if bars.empty:
        return bars
    keep = bars["barTime"] > bars["sym"].map(lambda s: last_pub.get(s, pd.Timestamp.min))
    return bars[keep].sort_values(["barTime", "sym"]).reset_index(drop=True)


# --------------------------------------------------------------------------- #
# sinks                                                                      #
# --------------------------------------------------------------------------- #
class CsvSink:
    def __init__(self, directory: Path, exchange: str, table: str):
        self.dir = directory
        self.exchange = exchange
        self.table = table
        self.dir.mkdir(parents=True, exist_ok=True)

    def write(self, rows: pd.DataFrame) -> None:
        # UTC date, matching barTime's own convention (m1_common.normalise_bars) -
        # not the exchange-local session tz, which governs polling/gating only.
        stem = self.table if self.table.endswith(self.exchange) else f"{self.table}_{self.exchange}"
        path = self.dir / f"{stem}_{datetime.now(timezone.utc):%Y%m%d}.csv"
        new = not path.exists()
        out = rows.copy()
        out["exchange"] = self.exchange
        out["barTime"] = out["barTime"].dt.strftime("%Y-%m-%dT%H:%M:%S")
        out[CSV_HEADER].to_csv(path, mode="a", header=new, index=False)

    def close(self):
        pass


class TpSink:
    def __init__(self, host: str, port: int, exchange: str, table: str):
        import numpy
        if not hasattr(numpy, "bool"):
            numpy.bool = numpy.bool_
        if not hasattr(numpy, "string_"):
            numpy.string_ = numpy.bytes_
        from qpython import qconnection
        self._np = numpy
        self._qconnection = qconnection
        self.exchange = exchange
        self.table = table
        self.q = self._connect(host, port)

    def _connect(self, host, port, retries=3, delay=5):
        for a in range(1, retries + 1):
            try:
                q = self._qconnection.QConnection(host=host, port=port, timeout=5)
                q.open()
                if q.is_connected():
                    log.info("connected to tickerplant %s:%d (%s)", host, port, q.protocol_version)
                    return q
            except Exception as e:  # noqa: BLE001
                log.warning("tp connect attempt %d/%d failed: %s", a, retries, e)
            if a < retries:
                time.sleep(delay)
        raise ConnectionError(f"cannot reach tickerplant {host}:{port}")

    def write(self, rows: pd.DataFrame) -> None:
        np = self._np
        from qpython.qcollection import qlist
        from qpython.qtype import QSYMBOL_LIST
        syms = qlist(np.array(rows["sym"].tolist(), dtype=np.string_), qtype=QSYMBOL_LIST)
        exch = qlist(np.array([self.exchange] * len(rows), dtype=np.string_), qtype=QSYMBOL_LIST)
        bt = [np.datetime64(t, "ns") for t in rows["barTime"].dt.to_pydatetime()]
        data = [
            syms, bt,
            [float(x) for x in rows["open"]], [float(x) for x in rows["high"]],
            [float(x) for x in rows["low"]], [float(x) for x in rows["close"]],
            [int(x) for x in rows["volume"]], exch,
        ]
        self.q.sendAsync("upd", np.string_(self.table), data)

    def close(self):
        try:
            self.q.close()
        except Exception:  # noqa: BLE001
            pass


# --------------------------------------------------------------------------- #
# loop                                                                       #
# --------------------------------------------------------------------------- #
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
            fresh = completed_new(fetch_bars(tickers, batch_size), last_pub)
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
    p = argparse.ArgumentParser(description="Live 1m OHLCV feed handler for one exchange's equities")
    p.add_argument("--exchange", required=True, choices=exchanges.keys())
    p.add_argument("--tickers", default=os.environ.get("M1_FEED_TICKERS"),
                   help="default: exchanges/<key>_tickers.csv")
    p.add_argument("--sink", choices=("csv", "tp"), default="csv")
    p.add_argument("--csv-dir", default=str(HERE / "live"))
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
    tickers_path = Path(args.tickers) if args.tickers else HERE / spec.tickers_filename()
    tickers = load_tickers(tickers_path)
    log.info("loaded %d %s tickers from %s", len(tickers), spec.key, tickers_path)

    if args.sink == "csv":
        sink = CsvSink(Path(args.csv_dir), spec.key, spec.table)
    else:
        sink = TpSink(args.host, args.port, spec.key, spec.table)
    try:
        run(sink, tickers, spec, tzinfo, args.interval, args.batch_size,
            not args.no_session, once=args.once)
    except KeyboardInterrupt:
        log.info("shutting down")
    finally:
        sink.close()


if __name__ == "__main__":
    main()

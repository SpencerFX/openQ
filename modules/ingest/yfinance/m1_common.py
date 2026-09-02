#!/usr/bin/env python3
"""
m1_common.py

Helpers shared by m1_backfill.py / m1_feed.py / m1_to_kdb.py: ticker-file IO,
batching, and turning a yfinance 1m frame into the canonical long shape
[sym, barTime, open, high, low, close, volume] with barTime in UTC, tz
stripped - matching every other clock-based decision in this repo (kdb+'s
own `.z.d`/`.z.p`, the HDB's date partitioning, the scheduled EOD trigger in
eod_housekeeping.q). Previously this stored exchange-local wall-clock time
instead (HKT/JST/...); that mismatch between UTC-based control-plane logic
and local-time-based data was a real, confirmed contributor to an EOD
promotion mistakenly overwriting/losing a real day's data - see
eod_housekeeping.q's header. Exchange-local time is still used for SESSION
GATING (exchanges.py's poll_start/poll_end, m1_feed.py's in_session()) since
that's inherently a local-wall-clock question ("is the market open right
now") - only the stored bar timestamps changed.
"""

from __future__ import annotations

import csv
from datetime import datetime
from pathlib import Path

import pandas as pd

BAR_COLS = ["barTime", "open", "high", "low", "close", "volume"]
LONG_COLS = ["sym"] + BAR_COLS


def now_hms() -> str:
    return datetime.now().strftime("%H:%M:%S")


def load_tickers(path: Path, limit: int = 0) -> list[str]:
    p = Path(path)
    if not p.exists():
        raise SystemExit(f"no ticker file {p} - run:  python m1_universe.py --exchange <key>")
    # utf-8 explicitly: universe files carry non-ASCII names (e.g. JPX/nikkei)
    with open(p, newline="", encoding="utf-8") as f:
        rows = [r["ticker"].strip() for r in csv.DictReader(f) if r.get("ticker", "").strip()]
    if not rows:
        raise SystemExit(f"{p} has no `ticker column / no rows")
    return rows[:limit] if limit else rows


def chunked(seq, n):
    for i in range(0, len(seq), n):
        yield seq[i : i + n]


def split_batch(data: pd.DataFrame, batch: list[str]) -> dict[str, pd.DataFrame]:
    """yf.download returns a (ticker, field) column MultiIndex for a batch,
    or a plain frame for a single ticker."""
    out: dict[str, pd.DataFrame] = {}
    if isinstance(data.columns, pd.MultiIndex):
        present = set(data.columns.get_level_values(0))
        for s in batch:
            out[s] = data[s].copy() if s in present else pd.DataFrame()
    else:
        out[batch[0]] = data.copy()
    return out


def normalise_bars(raw: pd.DataFrame, sym: str | None = None) -> pd.DataFrame:
    """One ticker's yfinance 1m frame -> canonical rows. barTime is converted
    to UTC then made naive (see module header). Rows with a null close are
    dropped."""
    cols = LONG_COLS if sym is not None else BAR_COLS
    if raw is None or raw.empty:
        return pd.DataFrame(columns=cols)
    raw = raw.rename(
        columns={"Open": "open", "High": "high", "Low": "low", "Close": "close", "Volume": "volume"}
    ).reset_index()
    tcol = "Datetime" if "Datetime" in raw.columns else raw.columns[0]
    raw["barTime"] = pd.to_datetime(raw[tcol], utc=True).dt.tz_localize(None)
    for c in ("open", "high", "low", "close", "volume"):
        if c not in raw.columns:
            raw[c] = pd.NA
    for c in ("open", "high", "low", "close"):
        raw[c] = pd.to_numeric(raw[c], errors="coerce")
    raw["volume"] = pd.to_numeric(raw["volume"], errors="coerce").fillna(0).round().astype("int64")
    raw = raw.dropna(subset=["close"])
    raw = raw.drop_duplicates(subset="barTime").sort_values("barTime").reset_index(drop=True)
    if sym is not None:
        raw["sym"] = sym
    return raw[cols]

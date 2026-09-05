#!/usr/bin/env python3
"""
core.py - shared library for the yfinance ingest CLIs (universe.py,
backfill.py, to_kdb.py, feed.py). Everything that is neither exchange-
specific (exchanges.py) nor kdb-facing (kdb.py) lives here.

  Cadence         the ONE seam between 1-minute and daily ingest: the
                  yfinance interval, the raw frame's time column, the
                  on-disk timestamp column + its staging-CSV format, the
                  .q loader, the hist/ subdir, and the kdb table-name
                  transform. Two instances: M1, D1.
  load_tickers / chunked / split_batch / now_hms   frame + IO helpers
  normalise()     one yfinance OHLCV frame -> canonical rows, cadence-aware
  merge_write()   append + de-dup a per-symbol Parquet, cadence-aware
  fetch_history() page Yahoo for one cadence's history over a universe
  fetch_today()   one poll of today's 1m bars (feed.py)

Time convention: minute bars are stored in UTC with the tz stripped, so
`date$barTime` partitioning always agrees with kdb+'s .z.d / the HDB's
date partitioning / eod_housekeeping.q's EOD trigger. Daily bars are the
calendar date, tz stripped and floored to midnight. Storing exchange-local
wall-clock instead was a real contributor to an EOD overwrite incident -
see eod_housekeeping.q's header. Exchange-local time is still used for
live-feed session gating (exchanges.py poll_start/poll_end), never for
anything written to disk.

Deps: pandas (+ yfinance, imported lazily by the fetch_* functions only).
"""

from __future__ import annotations

import csv
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable

import pandas as pd

# modules/ingest/yfinance/ - the scripts live in py/, but the data dirs
# (exchanges/, hist/, hist_d1/, live/, .stage/) and the q/ loaders sit at
# the module root. Every CLI resolves those against MODULE_DIR.
MODULE_DIR = Path(__file__).resolve().parents[1]

_RENAME = {"Open": "open", "High": "high", "Low": "low",
           "Close": "close", "Volume": "volume"}
_NUMERIC = ("open", "high", "low", "close", "volume")
_PRICE = ("open", "high", "low", "close")

WINDOW_DAYS = 7          # <= Yahoo's per-request 1m cap (8d); 7 leaves headroom
MAX_LOOKBACK_DAYS = 30   # Yahoo keeps ~30d of 1m history


# --------------------------------------------------------------------------- #
# cadence                                                                    #
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class Cadence:
    name: str                       # "m1" | "d1" ; also the --cadence value
    interval: str                   # yfinance interval
    raw_time_col: str               # time column in the yfinance frame
    ts_col: str                     # canonical / on-disk time column
    ts_fmt: str                     # strftime for the staging CSV
    hist_subdir: str                # per-symbol Parquet dir under the module
    utc: bool                       # parse the raw time as UTC before stripping tz
    floor_day: bool                 # floor the timestamp to midnight (daily)
    _table: Callable[[str], str]    # ExchangeSpec.table -> target kdb table
    # both cadences share one schema-driven loader, load_yfinance.q (kdb.LOADER_Q):
    # it reads the column order + parse types from the target table's `meta`.

    @property
    def bar_cols(self) -> list[str]:
        return [self.ts_col, "open", "high", "low", "close", "volume"]

    @property
    def long_cols(self) -> list[str]:
        return ["sym"] + self.bar_cols

    def table_for(self, spec_table: str) -> str:
        return self._table(spec_table)


M1 = Cadence(
    name="m1", interval="1m", raw_time_col="Datetime", ts_col="barTime",
    ts_fmt="%Y-%m-%dT%H:%M:%S", hist_subdir="hist",
    utc=True, floor_day=False, _table=lambda t: t,
)
D1 = Cadence(
    name="d1", interval="1d", raw_time_col="Date", ts_col="date",
    ts_fmt="%Y-%m-%d", hist_subdir="hist_d1",
    utc=False, floor_day=True, _table=lambda t: t.replace("_m1_", "_d1_"),
)
CADENCES: dict[str, Cadence] = {M1.name: M1, D1.name: D1}


def cadence(name: str) -> Cadence:
    try:
        return CADENCES[name]
    except KeyError:
        raise SystemExit(f"unknown --cadence {name!r} (choose m1 or d1)")


# --------------------------------------------------------------------------- #
# small helpers                                                              #
# --------------------------------------------------------------------------- #
def now_hms() -> str:
    return datetime.now().strftime("%H:%M:%S")


def chunked(seq, n):
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


def load_tickers(path: Path, limit: int = 0) -> list[str]:
    p = Path(path)
    if not p.exists():
        raise SystemExit(f"no ticker file {p} - run:  python universe.py --exchange <key>")
    # utf-8 explicitly: universe files carry non-ASCII names (e.g. JPX/nikkei)
    with open(p, newline="", encoding="utf-8") as f:
        rows = [r["ticker"].strip() for r in csv.DictReader(f) if r.get("ticker", "").strip()]
    if not rows:
        raise SystemExit(f"{p} has no `ticker column / no rows")
    return rows[:limit] if limit else rows


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


# --------------------------------------------------------------------------- #
# frame shaping                                                              #
# --------------------------------------------------------------------------- #
def normalise(raw: pd.DataFrame, cad: Cadence, sym: str | None = None) -> pd.DataFrame:
    """One ticker's yfinance OHLCV frame -> canonical rows in cad.bar_cols
    order (or cad.long_cols when sym is given). The time column is converted
    per the cadence (M1: UTC then tz-stripped; D1: tz-stripped, floored to
    the date). Rows with a null close are dropped, duplicates on the time
    column collapsed."""
    cols = cad.long_cols if sym is not None else cad.bar_cols
    if raw is None or raw.empty:
        return pd.DataFrame(columns=cols)
    raw = raw.rename(columns=_RENAME).reset_index()
    tcol = cad.raw_time_col if cad.raw_time_col in raw.columns else raw.columns[0]
    t = pd.to_datetime(raw[tcol], utc=cad.utc)
    if getattr(t.dt, "tz", None) is not None:
        t = t.dt.tz_localize(None)
    if cad.floor_day:
        t = t.dt.normalize()
    raw[cad.ts_col] = t
    for c in _NUMERIC:
        if c not in raw.columns:
            raw[c] = pd.NA
    for c in _PRICE:
        raw[c] = pd.to_numeric(raw[c], errors="coerce")
    raw["volume"] = pd.to_numeric(raw["volume"], errors="coerce").fillna(0).round().astype("int64")
    raw = (raw.dropna(subset=["close"])
              .drop_duplicates(subset=cad.ts_col)
              .sort_values(cad.ts_col)
              .reset_index(drop=True))
    if sym is not None:
        raw["sym"] = sym
    return raw[cols]


def merge_write(path: Path, fresh: pd.DataFrame, cad: Cadence) -> int:
    """Append fresh rows to a per-symbol Parquet, de-duplicating on the
    cadence's time column (newest wins). Returns the final row count."""
    if fresh is None or fresh.empty:
        return 0
    if path.exists():
        try:
            fresh = pd.concat([pd.read_parquet(path), fresh], ignore_index=True)
        except Exception:  # noqa: BLE001  - a corrupt/partial file: just overwrite
            pass
    fresh[cad.ts_col] = pd.to_datetime(fresh[cad.ts_col])
    fresh = (fresh.drop_duplicates(subset=cad.ts_col, keep="last")
                  .sort_values(cad.ts_col)
                  .reset_index(drop=True)[cad.bar_cols])
    fresh.to_parquet(path, engine="pyarrow", index=False)
    return len(fresh)


# --------------------------------------------------------------------------- #
# Yahoo fetch                                                                #
# --------------------------------------------------------------------------- #
def _yf():
    try:
        import yfinance as yf
    except ImportError:
        raise SystemExit("yfinance is not installed.  pip install yfinance pandas pyarrow")
    return yf


def _history_calls(cad: Cadence, *, days: int, start: str | None, end: str | None) -> list[dict]:
    """The list of yf.download keyword sets that cover the requested span.
    M1 pages backwards in <=WINDOW_DAYS windows (Yahoo caps 1m history at
    ~30d / <=8d per request); D1 is one call - period=max, or a bounded
    start[/end]."""
    if cad.name == "m1":
        out, span = [], min(days, MAX_LOOKBACK_DAYS)
        edge = datetime.now(timezone.utc).date() + timedelta(days=1)
        while span > 0:
            step = min(WINDOW_DAYS, span)
            out.append({"start": (edge - timedelta(days=step)).isoformat(), "end": edge.isoformat()})
            edge -= timedelta(days=step)
            span -= step
        return out
    if start:
        return [{"start": start, **({"end": end} if end else {})}]
    return [{"period": "max"}]


def fetch_history(symbols, cad: Cadence, *, days: int = MAX_LOOKBACK_DAYS,
                  start: str | None = None, end: str | None = None,
                  batch_size: int = 40, sleep: float = 1.5, log=print) -> dict[str, pd.DataFrame]:
    """Download one cadence's history for every symbol and return
    {sym: concatenated raw-normalised frame} (only symbols with data)."""
    yf = _yf()
    calls = _history_calls(cad, days=days, start=start, end=end)
    base = dict(interval=cad.interval, group_by="ticker", auto_adjust=False,
                actions=False, threads=True, progress=False)
    acc: dict[str, list[pd.DataFrame]] = {s: [] for s in symbols}
    for ci, call in enumerate(calls, 1):
        for bi, batch in enumerate(chunked(symbols, batch_size), 1):
            try:
                data = yf.download(tickers=batch, **base, **call)
            except Exception as exc:  # noqa: BLE001
                log(f"[{now_hms()}] call {ci}/{len(calls)} batch {bi}: {exc}")
                continue
            if data is None or data.empty:
                continue
            parts = split_batch(data, batch)
            for s in batch:
                f = normalise(parts.get(s), cad)
                if not f.empty:
                    acc[s].append(f)
            if sleep:
                time.sleep(sleep)
        if len(calls) > 1:
            log(f"[{now_hms()}] window {ci}/{len(calls)} {call.get('start', '')}..{call.get('end', '')} done")
    return {s: pd.concat(v, ignore_index=True) for s, v in acc.items() if v}


def fetch_today(tickers, batch_size: int = 40, log=None) -> pd.DataFrame:
    """One poll of today's 1m bars for the universe -> long frame
    [sym, barTime(naive UTC), open, high, low, close, volume]."""
    yf = _yf()
    frames = []
    for batch in chunked(tickers, batch_size):
        try:
            data = yf.download(tickers=batch, period="1d", interval="1m", group_by="ticker",
                               auto_adjust=False, actions=False, threads=True, progress=False)
        except Exception as exc:  # noqa: BLE001
            if log:
                log.warning("batch fetch failed (%d syms): %s", len(batch), exc)
            continue
        if data is None or data.empty:
            continue
        parts = split_batch(data, batch)
        for s in batch:
            f = normalise(parts.get(s), M1, sym=s)
            if not f.empty:
                frames.append(f)
    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame(columns=M1.long_cols)

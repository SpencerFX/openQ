#!/usr/bin/env python3
"""
exchanges.py

Registry of the per-exchange facts the m1 ingest scripts need, keyed by the
symbol that goes in eq_m1_yfinance's `exchange` column:

    key           kdb `exchange value / --exchange argument
    name          human label
    tz            IANA timezone for barTime (tz-stripped) and session gating
    poll_start    local (h, m) to begin polling  (a little before the open)
    poll_end      local (h, m) to stop polling   (a little after the close)
    yahoo_suffix  appended to the native code for the Yahoo ticker
    to_yahoo()    native listing code  -> Yahoo ticker
    build_universe(args) -> DataFrame  (>=1 column `ticker`, plus code/name/... where known)

Add an exchange by appending one ExchangeSpec to EXCHANGES with a
build_universe callable; the four m1_*.py scripts pick everything else up
from here.

Deps: pandas (+ openpyxl for the HKEX universe).
"""

from __future__ import annotations

import csv
import io
import sys
import urllib.request
from dataclasses import dataclass
from datetime import time as _time
from typing import Callable, Optional

import pandas as pd

_UA = {"User-Agent": "Mozilla/5.0 (openQ m1 ingest)"}


def _get(url: str, timeout: int = 60) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers=_UA), timeout=timeout) as r:
        return r.read()


# --------------------------------------------------------------------------- #
# spec                                                                       #
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class ExchangeSpec:
    key: str
    name: str
    tz: str
    poll_start: tuple[int, int]
    poll_end: tuple[int, int]
    yahoo_suffix: str
    _to_yahoo: Callable[["ExchangeSpec", str], str]
    _universe: Callable[["ExchangeSpec", Optional[object]], pd.DataFrame]
    table: str = "eq_m1_yfinance"   # kdb table this exchange's bars land in;
                                    # every venue currently shares eq_m1_yfinance
                                    # (distinguished by the `exchange column) -
                                    # override only to route one to its own table

    def to_yahoo(self, code: str) -> str:
        return self._to_yahoo(self, code)

    def build_universe(self, args=None) -> pd.DataFrame:
        df = self._universe(self, args)
        if "ticker" not in df.columns or df.empty:
            raise SystemExit(f"{self.key}: universe builder produced no tickers")
        return df.drop_duplicates(subset="ticker").reset_index(drop=True)

    def tickers_filename(self) -> str:
        # relative to modules/ingest/yfinance/ : one CSV per exchange under exchanges/
        return f"exchanges/{self.key}_tickers.csv"

    def poll_window(self) -> tuple[_time, _time]:
        return _time(*self.poll_start), _time(*self.poll_end)


# --------------------------------------------------------------------------- #
# ticker formatting                                                          #
# --------------------------------------------------------------------------- #
def _yahoo_hk(spec: ExchangeSpec, code: str) -> str:
    return f"{int(str(code).strip()):04d}{spec.yahoo_suffix}"


def _yahoo_plain(spec: ExchangeSpec, code: str) -> str:
    # US tickers: Yahoo uses '-' where the listing feeds use '.' / '$'
    return str(code).strip().upper().replace(".", "-").replace("$", "-") + spec.yahoo_suffix


def _yahoo_suffix_only(spec: ExchangeSpec, code: str) -> str:
    return str(code).strip().upper() + spec.yahoo_suffix


# --------------------------------------------------------------------------- #
# universe builders                                                          #
# --------------------------------------------------------------------------- #
_HKEX_LOS = "https://www.hkex.com.hk/eng/services/trading/securities/securitieslists/ListOfSecurities.xlsx"
_HKEX_KEEP_DEFAULT = {"Equity"}


def _universe_hkex(spec: ExchangeSpec, args) -> pd.DataFrame:
    keep = set(_HKEX_KEEP_DEFAULT)
    if getattr(args, "include_reits", False):
        keep.add("Real Estate Investment Trusts")
    if getattr(args, "include_trust", False):
        keep.add("Trust")
    if getattr(args, "include_etp", False):
        keep.add("Exchange Traded Products")
    url = getattr(args, "url", None) or _HKEX_LOS
    df = pd.read_excel(io.BytesIO(_get(url)), sheet_name=0, header=2, dtype=str)
    df.columns = [str(c).strip() for c in df.columns]
    df = df.rename(columns={
        "Stock Code": "code", "Name of Securities": "name",
        "Category": "category", "Sub-Category": "subcategory", "Board Lot": "board_lot",
    })
    df = df[df["code"].notna() & df["code"].str.strip().str.len().gt(0)]
    df = df[df["category"].isin(keep)]
    df["code"] = df["code"].str.strip()
    df["ticker"] = df["code"].map(lambda c: spec.to_yahoo(c))
    df["name"] = df["name"].str.strip()
    df["subcategory"] = df.get("subcategory", "").fillna("").str.strip()
    df["board_lot"] = df.get("board_lot", "").fillna("").str.replace(",", "", regex=False).str.strip()
    return df[["ticker", "code", "name", "subcategory", "board_lot"]].sort_values("code")


_NASDAQ_LISTED = "https://www.nasdaqtrader.com/dynamic/SymDir/nasdaqlisted.txt"
_OTHER_LISTED = "https://www.nasdaqtrader.com/dynamic/SymDir/otherlisted.txt"


def _pipe_rows(url: str) -> list[dict]:
    txt = _get(url).decode("utf-8", "replace")
    lines = [ln for ln in txt.splitlines() if ln and not ln.startswith("File Creation Time")]
    return list(csv.DictReader(io.StringIO("\n".join(lines)), delimiter="|"))


def _us_common(rows, code_col, keep_row, include_etfs):
    out = []
    for r in rows:
        if r.get("Test Issue", "").strip() == "Y":
            continue
        if not include_etfs and r.get("ETF", "").strip() == "Y":
            continue
        if not keep_row(r):
            continue
        code = r[code_col].strip()
        if code:
            out.append({"code": code, "name": r.get("Security Name", "").strip()})
    return out


def _universe_nasdaq(spec: ExchangeSpec, args) -> pd.DataFrame:
    inc = getattr(args, "include_etfs", False)
    rows = _us_common(_pipe_rows(_NASDAQ_LISTED), "Symbol", lambda r: True, inc)
    df = pd.DataFrame(rows)
    df["ticker"] = df["code"].map(lambda c: spec.to_yahoo(c))
    return df[["ticker", "code", "name"]].sort_values("code")


def _universe_nyse(spec: ExchangeSpec, args) -> pd.DataFrame:
    inc = getattr(args, "include_etfs", False)
    rows = _us_common(_pipe_rows(_OTHER_LISTED), "ACT Symbol",
                      lambda r: r.get("Exchange", "").strip() == "N", inc)
    df = pd.DataFrame(rows)
    df["ticker"] = df["code"].map(lambda c: spec.to_yahoo(c))
    return df[["ticker", "code", "name"]].sort_values("code")


_JPX_LIST = "https://www.jpx.co.jp/markets/statistics-equities/misc/tvdivq0000001vg2-att/data_j.xls"


def _universe_jpx(spec: ExchangeSpec, args) -> pd.DataFrame:
    """JPX 'listed issues' file (data_j.xls). Fixed positional layout:
    0 date, 1 code, 2 name, 3 market/product segment, 4-9 sector/scale.
    Keep the domestic-stock segments (Prime / Standard / Growth, all tagged
    with the substring 内国株式); drop ETF/ETN, REIT, PRO Market, foreign."""
    url = getattr(args, "url", None) or _JPX_LIST
    raw = pd.read_excel(io.BytesIO(_get(url)), dtype=str)   # needs xlrd for .xls
    raw = raw.rename(columns={raw.columns[1]: "code", raw.columns[2]: "name",
                              raw.columns[3]: "segment"})
    raw = raw[raw["code"].notna() & raw["code"].str.strip().str.len().gt(0)]
    if not getattr(args, "all_segments", False):
        raw = raw[raw["segment"].astype(str).str.contains("内国株式", na=False)]
    raw["code"] = raw["code"].str.strip()
    raw["ticker"] = raw["code"].map(lambda c: spec.to_yahoo(c))
    raw["name"] = raw["name"].str.strip()
    raw["subcategory"] = raw["segment"].str.strip()
    return raw[["ticker", "code", "name", "subcategory"]].sort_values("code")


def _universe_lse(spec: ExchangeSpec, args) -> pd.DataFrame:
    src = getattr(args, "universe_file", None)
    if not src:
        raise SystemExit(
            "lse: pass --universe-file <csv> with a `code column (LSE TIDM), e.g. exported "
            "from https://www.londonstockexchange.com/reports?tab=instruments"
        )
    df = pd.read_csv(src, dtype=str)
    col = next((c for c in df.columns if c.strip().lower() in ("code", "tidm", "symbol")), None)
    if col is None:
        raise SystemExit("lse: --universe-file needs a code/TIDM/symbol column")
    df = df.rename(columns={col: "code"})
    df["code"] = df["code"].str.strip()
    df = df[df["code"].str.len().gt(0)]
    df["ticker"] = df["code"].map(lambda c: spec.to_yahoo(c))
    if "name" not in df.columns:
        df["name"] = ""
    return df[["ticker", "code", "name"]].sort_values("code")


# --------------------------------------------------------------------------- #
# registry                                                                   #
# --------------------------------------------------------------------------- #
EXCHANGES: dict[str, ExchangeSpec] = {
    "hkex": ExchangeSpec(
        key="hkex", name="Hong Kong Exchange", tz="Asia/Hong_Kong",
        poll_start=(9, 15), poll_end=(16, 15), yahoo_suffix=".HK",
        _to_yahoo=_yahoo_hk, _universe=_universe_hkex,
    ),
    "nasdaq": ExchangeSpec(
        key="nasdaq", name="Nasdaq", tz="America/New_York",
        poll_start=(9, 25), poll_end=(16, 5), yahoo_suffix="",
        _to_yahoo=_yahoo_plain, _universe=_universe_nasdaq,
    ),
    "nyse": ExchangeSpec(
        key="nyse", name="New York Stock Exchange", tz="America/New_York",
        poll_start=(9, 25), poll_end=(16, 5), yahoo_suffix="",
        _to_yahoo=_yahoo_plain, _universe=_universe_nyse,
    ),
    "lse": ExchangeSpec(
        key="lse", name="London Stock Exchange", tz="Europe/London",
        poll_start=(7, 55), poll_end=(16, 35), yahoo_suffix=".L",
        _to_yahoo=_yahoo_suffix_only, _universe=_universe_lse,
    ),
    # Japan (Tokyo Stock Exchange, from the JPX listed-issues file).
    "nikkei": ExchangeSpec(
        key="nikkei", name="Tokyo Stock Exchange (JPX)", tz="Asia/Tokyo",
        poll_start=(8, 55), poll_end=(15, 45), yahoo_suffix=".T",
        _to_yahoo=_yahoo_suffix_only, _universe=_universe_jpx,
    ),
}


def get(key: str) -> ExchangeSpec:
    try:
        return EXCHANGES[key.lower()]
    except KeyError:
        sys.exit(f"unknown --exchange '{key}'. known: {', '.join(sorted(EXCHANGES))}")


def keys() -> list[str]:
    return sorted(EXCHANGES)

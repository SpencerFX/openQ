#!/usr/bin/env python3
"""
kdb.py - the kdb+-facing half of the yfinance ingest lib.

  default_q_exe / run_loader   invoke load_yfinance.q on a staging CSV
  stream_parquet_dir           per-symbol Parquet -> one staging CSV in the
                               loader's column order (cadence-aware)
  CsvSink / TpSink             feed.py's two live outputs: a daily CSV in
                               loader-ingestable shape, or an openQ
                               tickerplant `upd

The staging CSV is always
    <ts_col>,sym,open,high,low,close,volume,exchange
where <ts_col> is barTime (M1, ISO naive UTC) or date (D1, YYYY-MM-DD).
One schema-driven loader, load_yfinance.q, ingests both: it derives the
parse-type string ("PSFFFFJS" / "DSFFFFJS") and the on-disk column order
from the target table's `meta` in schema_yfinance.q, so it needs -schema
alongside -stage/-db/-table.

Deps: pandas ; +qpython, numpy for TpSink ; run_loader needs q + a licence.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

from core import MODULE_DIR, Cadence, now_hms

LOADER_Q = MODULE_DIR / "q" / "load_yfinance.q"
SCHEMA_Q = MODULE_DIR.parents[2] / "schemas" / "schema_yfinance.q"   # openQ/schemas/

# feed.py is 1-minute only, so its CSV always leads with barTime
CSV_HEADER = ["barTime", "sym", "open", "high", "low", "close", "volume", "exchange"]


# --------------------------------------------------------------------------- #
# batch loader                                                               #
# --------------------------------------------------------------------------- #
def default_q_exe(qhome: str) -> Path:
    exe = "q.exe" if os.name == "nt" else "q"
    arch = "w64" if os.name == "nt" else ("l64" if sys.platform.startswith("linux") else "m64")
    return Path(qhome) / arch / exe


def stream_parquet_dir(hist_dir: Path, csv_path: Path, cad: Cadence,
                       exchange: str, log=print) -> tuple[int, int]:
    """Stream every <SYMBOL>.parquet in hist_dir into one staging CSV at
    csv_path, in cad's loader column order, tagged with `exchange.
    Returns (file count, row count)."""
    files = sorted(Path(hist_dir).glob("*.parquet"))
    if not files:
        sys.exit(f"no Parquet files in {hist_dir} - run:  python backfill.py "
                 f"--exchange {exchange} --cadence {cad.name}")
    out_cols = [cad.ts_col, "sym", "open", "high", "low", "close", "volume", "exchange"]
    rows, header = 0, True
    for i, f in enumerate(files, 1):
        df = pd.read_parquet(f, columns=cad.bar_cols)
        if df.empty:
            continue
        df[cad.ts_col] = pd.to_datetime(df[cad.ts_col])
        df = df.dropna(subset=["close"])
        if df.empty:
            continue
        df["sym"] = f.stem
        df["volume"] = df["volume"].fillna(0).round().astype("int64")
        for c in ("open", "high", "low", "close"):
            df[c] = df[c].astype("float64")
        df["exchange"] = exchange
        df[cad.ts_col] = df[cad.ts_col].dt.strftime(cad.ts_fmt)
        df[out_cols].to_csv(csv_path, mode="w" if header else "a", header=header, index=False)
        header = False
        rows += len(df)
        if i % 500 == 0 or i == len(files):
            log(f"[{now_hms()}] {i}/{len(files)} files, {rows:,} rows")
    return len(files), rows


def run_loader(csv_path: Path, cad: Cadence, *, db: str, table: str,
               q: str | None = None, qhome: str | None = None,
               schema: Path | None = None, log=print) -> None:
    qhome = qhome or os.environ.get("QHOME", "C:/q")
    qexe = Path(q) if q else default_q_exe(qhome)
    if not qexe.exists():
        sys.exit(f"q not found: {qexe} (pass --q / --qhome)")
    schema_q = Path(schema) if schema else SCHEMA_Q
    # cad is accepted for symmetry / future per-cadence loader knobs; the
    # loader itself is schema-driven and reads the shape from `meta table`.
    cmd = [str(qexe), str(LOADER_Q),
           "-stage", str(csv_path), "-db", str(db), "-table", table,
           "-schema", schema_q.as_posix()]
    log(f"[{now_hms()}] loading -> {db}\n  {' '.join(cmd)}")
    r = subprocess.run(cmd, env=dict(os.environ, QHOME=qhome), stdin=subprocess.DEVNULL)
    if r.returncode:
        sys.exit(f"q loader failed (exit {r.returncode})")


# --------------------------------------------------------------------------- #
# live sinks (feed.py)                                                       #
# --------------------------------------------------------------------------- #
class CsvSink:
    """Append completed bars to <dir>/<table>_<exchange>_YYYYMMDD.csv (UTC
    date) with the CSV_HEADER columns - exactly what load_yfinance.q
    ingests. No tickerplant / no qpython."""

    def __init__(self, directory: Path, exchange: str, table: str):
        self.dir = Path(directory)
        self.exchange = exchange
        self.table = table
        self.dir.mkdir(parents=True, exist_ok=True)

    def write(self, rows: pd.DataFrame) -> None:
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
    """Publish completed bars to an openQ tickerplant via qpython:
    q.sendAsync("upd", <table>, <column-oriented data>) in schema order
    minus the leading `timestamp (core/tp.q's .u.updB prepends it)."""

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
        import logging
        log = logging.getLogger("feed")
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


def make_sink(kind: str, *, csv_dir: Path, host: str, port: int, exchange: str, table: str):
    if kind == "csv":
        return CsvSink(csv_dir, exchange, table)
    if kind == "tp":
        return TpSink(host, port, exchange, table)
    raise SystemExit(f"unknown --sink {kind!r} (csv|tp)")

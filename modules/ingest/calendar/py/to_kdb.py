#!/usr/bin/env python3
"""
to_kdb.py - bulk-load fxStreet economic-calendar CSVs (one file per
calendar month: <year>/<year>-<month>.csv, e.g. econCalScraper/data/
2026/2026-09.csv) into the `econCal` table of a kdb+ date-partitioned
HDB (default C:/data/calendar).

Stdlib-only (no pandas/pyarrow - the source rows need no numeric
reshaping, just a straight column remap): every source row is rewritten
into one combined `|`-delimited staging file (no CSV quoting at all -
`|` never appears in the source, verified against the full archive;
event text does carry embedded commas and, rarely, double quotes, which
is exactly what a quote-aware `,`-CSV would need to escape and a plain
`|`-split does not), then load_calendar.q ingests it. Idempotent per
source file: a given month's file is authoritative for every date in it,
so re-running (e.g. after a fresh scrape) simply rewrites those date
partitions - see load_calendar.q's own header.

Deps: none beyond the stdlib for staging; needs q + a kdb+ licence
(QHOME) to actually load.

Usage:
  python to_kdb.py                                   # load the whole archive
  python to_kdb.py --glob "2026/*.csv"                # just 2026
  python to_kdb.py --glob "2026/2026-09.csv"          # just one month
  python to_kdb.py --src-dir <path> --db <hdbRoot>
  python to_kdb.py --no-load                          # staging file only
"""

from __future__ import annotations

import argparse
import csv
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

MODULE_DIR = Path(__file__).resolve().parents[1]          # modules/ingest/calendar/
LOADER_Q = MODULE_DIR / "q" / "load_calendar.q"
SCHEMA_Q = MODULE_DIR.parents[2] / "schemas" / "schema_calendar.q"   # openQ/schemas/
# econCalScraper is a sibling checkout of openQ, not a subdirectory of it.
DEFAULT_SRC = MODULE_DIR.parents[3] / "econCalScraper" / "data"

# Source header (fxStreet scrape) -> staging column order. `date_utc`
# becomes the partition key (`date`, col 1); `time_utc` gets ":00.000"
# appended (the source has no seconds) so kdb's "T"$ parses it directly.
STAGE_HEADER = ["date", "time", "country", "currency", "category", "event",
                "importance", "actual", "consensus", "previous", "revised",
                "unit", "potency", "allDay", "tentative", "preliminary",
                "report", "speech", "eventId"]

_BOOL = {"True": "1", "False": "0", "": "0"}


def now_hms() -> str:
    return datetime.now().strftime("%H:%M:%S")


def _clean(v: str) -> str:
    # Defensive only - verified absent from the full archive when this
    # loader was built, but a future re-scrape is out of our control:
    # strip anything that would break a delimiter-only (no quoting) read.
    return v.replace("|", "/").replace("\n", " ").replace("\r", " ").strip()


def to_stage_row(row: dict) -> str:
    vals = [
        row["date_utc"],
        row["time_utc"] + ":00.000",
        row["country"], row["currency"], row["category"],
        _clean(row["event"]),
        row["importance"],
        row["actual"], row["consensus"], row["previous"], row["revised"],
        row["unit"], row["potency"],
        _BOOL.get(row["is_all_day"], "0"), _BOOL.get(row["is_tentative"], "0"),
        _BOOL.get(row["is_preliminary"], "0"), _BOOL.get(row["is_report"], "0"),
        _BOOL.get(row["is_speech"], "0"),
        row["event_id"],
    ]
    return "|".join(vals)


def stage(files: list[Path], csv_path: Path, log=print) -> int:
    rows = 0
    with open(csv_path, "w", newline="", encoding="utf-8") as out:
        out.write("|".join(STAGE_HEADER) + "\n")
        for i, f in enumerate(files, 1):
            with open(f, newline="", encoding="utf-8") as fh:
                for row in csv.DictReader(fh):
                    out.write(to_stage_row(row) + "\n")
                    rows += 1
            if i % 24 == 0 or i == len(files):
                log(f"[{now_hms()}] {i}/{len(files)} files, {rows:,} rows")
    return rows


def default_q_exe(qhome: str) -> Path:
    exe = "q.exe" if os.name == "nt" else "q"
    arch = "w64" if os.name == "nt" else ("l64" if sys.platform.startswith("linux") else "m64")
    return Path(qhome) / arch / exe


def run_loader(csv_path: Path, *, db: str, schema: Path, q: str | None,
               qhome: str, table: str = "econCal", log=print) -> None:
    qexe = Path(q) if q else default_q_exe(qhome)
    if not qexe.exists():
        sys.exit(f"q not found: {qexe} (pass --q / --qhome)")
    cmd = [str(qexe), str(LOADER_Q),
           "-stage", str(csv_path), "-db", db, "-table", table,
           "-schema", schema.as_posix()]
    log(f"[{now_hms()}] loading -> {db}\n  {' '.join(cmd)}")
    r = subprocess.run(cmd, env=dict(os.environ, QHOME=qhome), stdin=subprocess.DEVNULL)
    if r.returncode:
        sys.exit(f"q loader failed (exit {r.returncode})")


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--src-dir", default=str(DEFAULT_SRC),
                   help=f"fxStreet data root (default: {DEFAULT_SRC})")
    p.add_argument("--glob", default="**/*.csv",
                   help="glob under --src-dir, e.g. '2026/*.csv' (default: everything)")
    p.add_argument("--db", default="C:/data/calendar")
    p.add_argument("--stage-dir", default=str(MODULE_DIR / ".stage"),
                   help="staging CSV dir (must NOT be inside the HDB root)")
    p.add_argument("--q", default=None)
    p.add_argument("--qhome", default=os.environ.get("QHOME", "C:/q"))
    p.add_argument("--schema", default=None, help="default: schemas/schema_calendar.q")
    p.add_argument("--table", default="econCal")
    p.add_argument("--no-load", action="store_true")
    p.add_argument("--keep-stage", action="store_true")
    return p.parse_args(argv)


def main(argv=None) -> None:
    args = parse_args(argv)
    src = Path(args.src_dir)
    files = sorted(src.glob(args.glob))
    if not files:
        sys.exit(f"no files matching {args.glob!r} under {src}")

    stage_dir = Path(args.stage_dir)
    stage_dir.mkdir(parents=True, exist_ok=True)
    csv_path = stage_dir / f"econCal_{datetime.now():%Y%m%d_%H%M%S}.csv"

    print(f"[{now_hms()}] staging {len(files)} file(s) from {src} -> {csv_path}")
    rows = stage(files, csv_path)
    mb = csv_path.stat().st_size / 1e6
    print(f"[{now_hms()}] staged {rows:,} rows ({mb:.1f} MB)")

    if args.no_load:
        return
    schema = Path(args.schema) if args.schema else SCHEMA_Q
    run_loader(csv_path, db=args.db, schema=schema, q=args.q, qhome=args.qhome,
               table=args.table)
    if not args.keep_stage:
        csv_path.unlink(missing_ok=True)
    print(f"[{now_hms()}] done")


if __name__ == "__main__":
    main()

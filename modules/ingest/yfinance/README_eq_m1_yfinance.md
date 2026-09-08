# eq_m1_yfinance — per-exchange 1-minute equity OHLCV ingest

Live feed handler **and** historical backfill for 1-minute bars of
exchange-listed cash equities from Yahoo Finance, landing in the
`eq_m1_yfinance` table — the minute-bar sibling of `schema_eq.q`'s daily
`eq_d1_yfinance`, in the same HDB root **`C:/data/db1/eq`**.

Every script takes `--exchange <key>` and pulls the timezone, trading-session
window, Yahoo ticker format, universe source **and target table** from
**`exchanges.py`**. Registered keys:

| key | venue | Yahoo ticker | universe source | table |
|---|---|---|---|---|
| `hkex` | Hong Kong Exchange | `NNNN.HK` | HKEX *List of Securities* | `eq_m1_yfinance` |
| `nyse` / `nasdaq` | NYSE / Nasdaq | `AAPL` | NASDAQ Trader symbol dirs | `eq_m1_yfinance` |
| `lse` | London (needs `--universe-file`) | `VOD.L` | user-supplied TIDM list | `eq_m1_yfinance` |
| `nikkei` | Tokyo Stock Exchange / JPX | `7203.T` | JPX `data_j.xls` (domestic stock) | `eq_m1_yfinance` |
| `rateidx` | CBOE US Treasury yield indices | `^IRX ^FVX ^TNX ^TYX` | fixed 4-ticker list | **`rateIndices_m1_yfinance`** |
| `futures` | US futures (CME Group / ICE US front-month) | `ES=F CL=F GC=F ZN=F 6E=F …` | curated ~50-ticker list | **`futures_m1_yfinance`** |
| `fx` | FX spot (7 USD majors + 21 G10 crosses) | `EURUSD=X` → stored `` `EURUSD `` | fixed 28-pair list | **`fx_m1_yfinance`** |

The cash-equity venues land in the **one** `eq_m1_yfinance` table, told apart
by the `exchange` column (`` `hkex`` / `` `nyse`` / `` `nasdaq`` / `` `nikkei`` …).
`rateidx`, `futures` and `fx` are not venues - each routes to its own table
(`rateIndices_m1_yfinance` / `futures_m1_yfinance` / `fx_m1_yfinance`; all
tables now share the one `schemas/schema_yfinance.q`, each with its own
`cfg_proc/modules/yfinance/*/` - `rateIndices` at 5080-5083/5136, `futures`
at 5084-5087/5137, `fx` at 5140-5143 + a 5120-5123 rdb2 bank) via its
`ExchangeSpec.table` override; same loader, `-table` picks the target.

`eq_m1_yfinance` and `fx_m1_yfinance` run the **full** openQ live pipeline
(`tp`/`rdb`/`idb`/`hdb`/`gw`/`housekeeping`) with an automatic daily EOD
promote; `rateIndices`/`futures` are `tp`/`rdb`/`hdb` only (batch-loaded).
See "Daily persistence" below.

**`fx` specifics** (`ExchangeSpec` fields): `_to_sym` drops the Yahoo `=X`
suffix so `EURUSD=X` is stored as `` `EURUSD ``; `exchange_value="yfinance"`
so the `exchange` column reads `` `yfinance `` (a source tag, not `` `fx``).
Both `fx_m1_yfinance` and `fx_d1_yfinance` live in **`C:/data/db1/efx`**,
alongside the read-only vendor FX archive (`fx_{tick,m1,d1}_{massive,dukasCopy}`)
— the loader only ever writes its own `fx_*_yfinance` partitions there.
Add anything by appending one `ExchangeSpec` to `EXCHANGES`.

Schema — [`../../../schemas/schema_yfinance.q`](../../../schemas/schema_yfinance.q)
(one merged file for every yfinance table — the three `*_m1_yfinance` and
two `*_d1_yfinance` tables; `eq_m1_yfinance` shape below):

```
timestamp  p   arrival stamp (tickerplant path) / = barTime (batch path)
sym        s   Yahoo ticker e.g. 0700.HK   `p# parted
barTime    p   the minute the bar covers, UTC, tz stripped (not exchange-local -
               `date$barTime` partitioning then always agrees with `.z.d`)
open       f
high       f
low        f
close      f
volume     j
exchange   s   `hkex / `nyse / `nasdaq / …
```
On disk: date-partitioned by `date$barTime`. `C:/data/db1/eq` also holds the
much longer-dated daily `eq_d1_yfinance`, so `load_yfinance.q` runs
`.Q.chk` on the root after writing — stubbing an empty `eq_m1_yfinance` into
every older partition (and an empty `eq_d1_yfinance` into any new minute-only
partition) so both tables span the union of partition dirs and neither
'`path`s on an out-of-range date.

`schema_yfinance.q` is the one schema for all five yfinance tables. It is the
only `schema_*.q` that reads `-procType` / `-name`: the two `*_d1_yfinance`
tables (no `timestamp`) are declared **only** in an HDB process, so a
tickerplant's `.u.tick` timestamp,sym check doesn't abort; and
`.oq.schema.tables[]` resolves the process `-name` (`<table>_<role>`) back to
the single table that pipeline owns, so an EOD/idb save can't write a sibling
table's partition. A manual `q schema_yfinance.q` with no `-name` sees all
five.

## Pieces

Layout: **`py/`** — Python CLIs + libs; **`q/`** — the q loader scripts;
**`exchanges/`** — generated per-exchange ticker CSVs (git-ignored, so are
`hist/`, `hist_d1/`, `live/`, `.stage/`, `.venv/`, all at the module root).

Four CLIs (`universe` / `backfill` / `to_kdb` / `feed`) over three importable
library modules. `backfill.py` and `to_kdb.py` take **`--cadence {m1,d1}`** —
one code path for minute and daily bars, differing only by a `Cadence` record
in `core.py` (interval, time column, staging-CSV format, `hist/` subdir,
`_m1_`→`_d1_` table rename). All CLIs resolve the module-root data dirs via
`core.MODULE_DIR`.

| file | what |
|---|---|
| `py/exchanges.py` | **lib** — registry: per-exchange tz, session window, ticker format, `build_universe()`, target `table` |
| `py/core.py` | **lib** — `Cadence` (`M1`/`D1`), `MODULE_DIR`, ticker IO, batching, `normalise()`, `merge_write()`, `fetch_history()` / `fetch_today()` |
| `py/kdb.py` | **lib** — `stream_parquet_dir()` + `run_loader()` (staging CSV → `q/load_yfinance.q`), and `feed.py`'s `CsvSink` / `TpSink` |
| `py/universe.py` | `--exchange K` → `exchanges/K_tickers.csv` (cadence-independent) |
| `py/backfill.py` | `--exchange K --cadence m1\|d1` → Yahoo history → per-symbol Parquet in `hist/K/` (m1, ≤7d pages, ~30d max) or `hist_d1/K/` (d1, `period=max`) |
| `py/to_kdb.py` | `--exchange K --cadence m1\|d1` → bulk-load those Parquet → the cadence's kdb table via `q/load_yfinance.q` |
| `py/feed.py` | `--exchange K` **live** (1-minute only): poll, emit each completed bar to `--sink tp` (tickerplant) or `--sink csv` |
| `q/load_yfinance.q` | **schema-driven** staging-CSV → date-partition writedown (à la `core/save.q`): reads the on-disk column order + CSV parse types from `-table`'s `meta` in `-schema`, so one loader covers both the `timestamp,sym,barTime,…` minute tables and the pure date-partitioned daily ones. Idempotent per date; per-date rewrite keeps other `-partkey` (default `exchange`) values' rows; trailing `.Q.chk`. |
| `q/eod_housekeeping.q` | `-hkscript` shared by **both** `eq_m1_yfinance`'s and `fx_m1_yfinance`'s housekeeping process — wall-clock EOD trigger that IPC-calls `.oq.idb.eod` on the live idb. Table-agnostic: `.oq.schema.tables[]` resolves the `-name` `<table>_housekeeping` to the one owned table; `-eodDayOffset` (0 = promote `.z.d`, eq's case / `-1` = promote the UTC day that just closed, fx's 24×5 case). See its own header. |

**Daily tables**: `to_kdb.py --cadence d1` derives the target table from the spec by `_m1_`→`_d1_`
(`rateidx`→`rateIndices_d1_yfinance`, `futures`→`futures_d1_yfinance`, `fx`→`fx_d1_yfinance`, equity venues→`eq_d1_yfinance`).

| table | `--db` root | span | config |
|---|---|---|---|
| `eq_d1_yfinance` | `C:/data/db1/eq` | 2010→ (US equities, `stockData/` loads it) | `cfg_proc/modules/eq/` :5090 |
| `futures_d1_yfinance` | **`C:/data/db1/futures`** (own root) | 2010→ | `cfg_proc/modules/yfinance/futures_d1_yfinance/` :5089 |
| `rateIndices_d1_yfinance` | **`C:/data/db1/rates`** (own root) | 1960→ | `cfg_proc/modules/yfinance/rateIndices_d1_yfinance/` :5088 |
| `fx_d1_yfinance` | **`C:/data/db1/efx`** (own root) | 2010→ (`--start 2010-01-01`); m1 sibling ~28d (Yahoo's 1m FX limit) | `cfg_proc/modules/yfinance/fx_d1_yfinance/` :5092 |

Three table pairs get their own dedicated root, each shared by both their m1
and d1 tables: `rateIndices_m1_yfinance`/`rateIndices_d1_yfinance` →
`C:/data/db1/rates` (deep history, `^IRX` back to 1960 - would otherwise
force `load_yfinance.q`'s `.Q.chk` to stub every eq sibling across ~13k
extra pre-2010 partitions); `futures_m1_yfinance`/`futures_d1_yfinance` →
`C:/data/db1/futures` (same 2010→ span as eq, no partition-explosion
reason - migrated purely to keep the futures dataset physically separate);
`fx_m1_yfinance`/`fx_d1_yfinance` → **`C:/data/db1/efx`**, the same root as
the pre-existing read-only vendor FX tick/m1/d1 archive integrated via
`schema_efx.q` (`fx_tick_massive`/`fx_m1_massive`/`fx_d1_massive`/etc.).
`to_kdb.py --exchange rateidx|futures|fx ...` and the matching cfg_proc
configs' `hdbroot` all point at their respective new roots.

**`fx`'s repointing to `efx` is a deliberate, knowing exception** to that
archive's long-standing "openQ never writes here" rule (it was built and
verified specifically as a read-only integration - see the EFX HDB
integration note in the core README/memory). `fx_m1_yfinance`'s tp/rdb now
write into that shared root on every EOD. Confirmed with the user before
making this change.

**Loaded 2026-09-06** via `py/to_kdb.py --exchange fx --cadence {d1,m1} --db C:/data/db1/efx`:
`fx_d1_yfinance` = 121,593 rows / 28 pairs / 2010-01-01→ (4,348 partitions);
`fx_m1_yfinance` = 765,266 rows / 28 pairs / ~28d (2026-08-09→09-04, 24
partitions — the earliest 1m window Yahoo serves fell just off the ~30d
edge). `sym` stored bare (`` `EURUSD ``, no `=X`); `exchange` = `` `yfinance ``;
both `` `p# `` on `sym`. The first d1 load paid the one-time `.Q.chk` stub
pass over `efx` (~70s for 4,348 partitions); the vendor `fx_*_massive` /
`fx_*_dukasCopy` tables were verified untouched.

**Consolidating rateIndices' m1 and d1 tables into one root was not just a
file move** - the m1 table's `sym`/`exchange` columns had been `.Q.en`'d
against eq's (large, shared) domain the whole time it lived there, while
the d1 table's had always used its own tiny (5-symbol) dedicated domain;
merging them required decoding m1's columns via eq's domain and
re-encoding them against d1's domain (reused as the new root's canonical
`sym` file) - a plain directory/file move would have left the m1 table's
enum codes resolving to the wrong (or blank) symbols. `futures` needed no
such re-encoding since both its tables were always enumerated against the
same eq domain, so that migration only needed eq's current `sym` file
copied alongside the moved data. The same lesson applies here: whenever
`fx` is eventually loaded into `efx`, its `sym`/`exchange` columns must be
enumerated fresh against `efx`'s existing domain (or reconciled the same
decode/re-encode way), never assumed compatible with any old domain file
from wherever `fx` lived before.

openQ process configs (generated by `py/gen_cfg.py` — don't hand-edit):
[`../../../cfg_proc/modules/yfinance/`](../../../cfg_proc/modules/yfinance/).
`eq_m1_yfinance`: tp :5060, rdb :5061/:5116, hdb :5063, idb :5117, gw :5119,
housekeeping :5118 (hdbroot `C:/data/db1/eq`). `fx_m1_yfinance`: tp :5140,
rdb :5141/:5120, hdb :5143, idb :5121, gw :5123, housekeeping :5122 (hdbroot
`C:/data/db1/efx`).

## Setup

```powershell
cd openQ\modules\ingest\yfinance
py -3.10 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt   # qpython+numpy only for --sink tp
```

## Run (example: HKEX)

```powershell
.\.venv\Scripts\python.exe py\universe.py --exchange hkex                       # -> exchanges/hkex_tickers.csv
.\.venv\Scripts\python.exe py\backfill.py --exchange hkex --cadence m1 --days 30 --resume
.\.venv\Scripts\python.exe py\to_kdb.py   --exchange hkex --cadence m1          # hist/hkex/ -> C:/data/db1/eq

# daily bars, same universe file
.\.venv\Scripts\python.exe py\backfill.py --exchange hkex --cadence d1 --start 2010-01-01
.\.venv\Scripts\python.exe py\to_kdb.py   --exchange hkex --cadence d1          # hist_d1/hkex/ -> eq_d1_yfinance

# live -> daily CSV (no tickerplant), then load it
.\.venv\Scripts\python.exe py\feed.py --exchange hkex --sink csv --csv-dir live
C:\q\w64\q.exe q\load_yfinance.q -stage live\eq_m1_yfinance_hkex_YYYYMMDD.csv -db C:/data/db1/eq -table eq_m1_yfinance -schema ../../../schemas/schema_yfinance.q

# live -> openQ tickerplant (start cfg_proc/modules/yfinance/eq_m1_yfinance tp+rdb+hdb first)
.\.venv\Scripts\python.exe py\feed.py --exchange hkex --sink tp --host localhost --port 5060
```

Other exchanges are identical, `--exchange nyse` / `nasdaq` / `lse` / `nikkei`
/ `rateidx` / `futures` / `fx` (`nyse`/`nasdaq` universes come from the
NASDAQ Trader symbol directory; `lse` needs `--universe-file <csv>` with a
TIDM column).
`feed.py` only polls inside that exchange's session; `--no-session` / `--once`
override.

## Daily persistence (eq_m1_yfinance, fx_m1_yfinance)

Both tables run the full openQ live pipeline, so once it's up they persist a
day at a time with no per-day command:

```powershell
# 1. start the 7 processes (tp, rdb x2, idb, hdb, gw, housekeeping)
bash scripts/startStop/startupAllByModule.sh yfinance/fx_m1_yfinance   # or .../eq_m1_yfinance

# 2. keep the feed running (hand-started / kept alive however you run the eq feeds)
.\.venv\Scripts\python.exe py\feed.py --exchange fx --sink tp --host localhost --port 5140
```

The `housekeeping` process (`q/eod_housekeeping.q`) then does the daily roll
on its own: every minute it checks the wall clock, and on the first tick past
`-eodTriggerTime` each UTC day it IPC-calls `.oq.idb.eod` on the idb, which
pivots that day's accumulated segments into the real dated HDB partition
under the module's `hdbroot` and clears the staging root. A marker file
(`<hdbroot>/.eod_markers/<date>`) makes it idempotent; `.oq.hk.hasForeignData`
makes it **skip** any date whose partition already holds real rows from
`backfill.py`+`to_kdb.py` (the historical loader), so the two ingest paths
don't fight.

- **eq_m1_yfinance**: `-eodTriggerTime 08:30:00.000`, `-eodDayOffset 0`
  (promote `.z.d`) — HKEX (08:00 UTC) and Tokyo (06:30 UTC) are both closed
  by 08:30 and produce nothing more that UTC day.
- **fx_m1_yfinance**: `-eodTriggerTime 00:30:00.000`, `-eodDayOffset -1`
  (promote `.z.d - 1`) — FX trades ~24×5, so the only complete day at any
  wall-clock time is the one that already ended; the roll fires 30 min after
  the UTC midnight boundary.

`rateIndices_m1_yfinance` / `futures_m1_yfinance` have no idb/housekeeping —
persist them with `to_kdb.py --cadence m1` (and `--cadence d1` covers every
`*_d1_yfinance` table).

## Reality check on the data source

Yahoo intraday is delayed (~15 min for HK) and 1m bars are best-effort (flat
zero-volume padding during lulls; only ~30 days of 1m history ever available).
This is a *delayed-bar collector*, not a real-time market-data feed. For true
real time, replace `core.fetch_today()` with a broker/vendor source
(Interactive Brokers, Futu OpenD, HKEX OMD-C, …) — `feed.py`'s bar-completion
logic and both sinks in `kdb.py` are source-agnostic and stay as they are.

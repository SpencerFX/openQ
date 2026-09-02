# eq_m1_yfinance — per-exchange 1-minute equity OHLCV ingest

Live feed handler **and** historical backfill for 1-minute bars of
exchange-listed cash equities from Yahoo Finance, landing in the
`eq_m1_yfinance` table — the minute-bar sibling of `schema_eq.q`'s daily
`eq_d1_yfinance`, in the same HDB root **`C:/data/db1/eq`**.

Every script takes `--exchange <key>` and pulls the timezone, trading-session
window, Yahoo ticker format, universe source **and target table** from
**`exchanges.py`**. Registered keys:

| key | venue | Yahoo ticker | universe source |
|---|---|---|---|
| `hkex` | Hong Kong Exchange | `NNNN.HK` | HKEX *List of Securities* |
| `nyse` / `nasdaq` | NYSE / Nasdaq | `AAPL` | NASDAQ Trader symbol dirs |
| `lse` | London (needs `--universe-file`) | `VOD.L` | user-supplied TIDM list |
| `nikkei` | Tokyo Stock Exchange / JPX | `7203.T` | JPX `data_j.xls` (domestic stock) |

All venues land in the **one** `eq_m1_yfinance` table, told apart by the
`exchange` column (`` `hkex`` / `` `nyse`` / `` `nasdaq`` / `` `nikkei`` …).
Add a venue by appending an `ExchangeSpec` to `EXCHANGES` (the `table=` field
defaults to `eq_m1_yfinance`; override it only to route one to its own table).

Schema — [`../../../schemas/schema_eq_m1_yfinance.q`](../../../schemas/schema_eq_m1_yfinance.q):

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
much longer-dated daily `eq_d1_yfinance`, so `load_eq_m1_yfinance.q` runs
`.Q.chk` on the root after writing — stubbing an empty `eq_m1_yfinance` into
every older partition (and an empty `eq_d1_yfinance` into any new minute-only
partition) so both tables span the union of partition dirs and neither
'`path`s on an out-of-range date.

## Pieces (all in `modules/ingest/yfinance/`)

| file | what |
|---|---|
| `exchanges.py` | registry: per-exchange tz, session window, ticker format, `build_universe()` |
| `m1_common.py` | shared helpers (ticker IO, batching, `normalise_bars`) |
| `m1_universe.py` | `--exchange K` → `exchanges/K_tickers.csv` |
| `m1_backfill.py` | `--exchange K` → Yahoo 1m history (≤7d pages, ~30d max) → per-symbol Parquet in `hist/K/` |
| `m1_to_kdb.py` | `--exchange K` → bulk-load `hist/K/*.parquet` → `eq_m1_yfinance` via `load_eq_m1_yfinance.q` |
| `m1_feed.py` | `--exchange K` **live**: poll 1m, emit each completed bar to `--sink tp` (tickerplant) or `--sink csv` |
| `load_eq_m1_yfinance.q` | staging-CSV → date-partition writedown (hand-rolled à la `core/save.q`; idempotent per date) |

openQ process configs: [`../../../cfg_proc/modules/eq_m1_yfinance/`](../../../cfg_proc/modules/eq_m1_yfinance/)
— `tp.json` (:5060), `rdb.json` (:5061/:5116), `hdb.json` (:5063, hdbroot `C:/data/db1/eq`).

## Setup

```powershell
cd openQ\modules\ingest\yfinance
py -3.10 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt   # qpython+numpy only for --sink tp
```

## Run (example: HKEX)

```powershell
.\.venv\Scripts\python.exe m1_universe.py --exchange hkex                 # -> exchanges/hkex_tickers.csv
.\.venv\Scripts\python.exe m1_backfill.py --exchange hkex --days 30 --resume
.\.venv\Scripts\python.exe m1_to_kdb.py   --exchange hkex                 # hist/hkex/ -> C:/data/db1/eq

# live -> daily CSV (no tickerplant), then load it
.\.venv\Scripts\python.exe m1_feed.py --exchange hkex --sink csv --csv-dir live
..\..\..\..\q\w64\q.exe load_eq_m1_yfinance.q -stage live\eq_m1_yfinance_hkex_YYYYMMDD.csv -db C:/data/db1/eq

# live -> openQ tickerplant (start cfg_proc/modules/eq_m1_yfinance tp+rdb+hdb first)
.\.venv\Scripts\python.exe m1_feed.py --exchange hkex --sink tp --host localhost --port 5060
```

Other exchanges are identical, `--exchange nyse` / `nasdaq` / `lse`
(`nyse`/`nasdaq` universes come from the NASDAQ Trader symbol directory;
`lse` needs `--universe-file <csv>` with a TIDM column). `m1_feed.py` only
polls inside that exchange's session; `--no-session` / `--once` override.

## Reality check on the data source

Yahoo intraday is delayed (~15 min for HK) and 1m bars are best-effort (flat
zero-volume padding during lulls; only ~30 days of 1m history ever available).
This is a *delayed-bar collector*, not a real-time market-data feed. For true
real time, implement `fetch_bars()` in `m1_feed.py` against a broker/vendor
source (Interactive Brokers, Futu OpenD, HKEX OMD-C, …) — the bar-completion
logic and both sinks are source-agnostic and stay as they are.

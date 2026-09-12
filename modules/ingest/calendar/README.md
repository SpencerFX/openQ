# calendar: fxStreet economic-calendar ingest

Bulk-loads the fxStreet economic-calendar CSVs scraped by
[econCalScraper](../../../../econCalScraper) (a sibling checkout, not part
of this repo - `<year>/<year>-<month>.csv`, 2010-2026, ~204k rows) into a
kdb+ date-partitioned HDB (default `C:/data/calendar`). Stdlib-only
Python + one schema-driven q loader - no live feed, no `cep.q`: same
"batch ingest, no process role of its own" shape as
`modules/ingest/yfinance/`, just without the vendor-API half of it.

## Data

`schemas/schema_calendar.q` defines one table, `econCal` - one row per
scheduled/released macro event (a release, a central-bank decision, a
bond auction, a speech, a market holiday, ...), partitioned by date.

| Column | Type | Notes |
|---|---|---|
| `time` | time | UTC release time (source has no seconds) |
| `country`, `currency` | symbol | ISO-ish 2-3 letter codes (also `EMU`) |
| `category` | symbol | 12 values - Economic Activity, Inflation, Capital Flows, Labor Market, Central Banks, Housing Market, Holidays, Bond Auctions, Interest Rates, Politics, Energy, Consumption |
| `event` | symbol | headline text, heavily repeated (~1,600 distinct over ~204k rows) |
| `importance` | symbol | `HIGH`/`MEDIUM`/`LOW`/`NONE` (`NONE` = holidays) |
| `actual`/`consensus`/`previous`/`revised` | float | null when the source cell is blank |
| `unit` | symbol | `$`/`%`/`£`/`€`/`¥`/blank - the figure's currency/percent sign, not a magnitude. Genuine UTF-8 glyphs; a non-UTF-8 terminal will render them oddly, the stored symbol is correct |
| `potency` | symbol | `B`/`K`/`M`/`T`/`ZERO`/blank - the figure's scale |
| `allDay`/`tentative`/`preliminary`/`report`/`speech` | boolean | |
| `eventId` | guid | fxStreet's own event-definition id - the same recurring event (e.g. "Nonfarm Payrolls") keeps the same `eventId` release over release, so it's the right key for one event's own time series (`event` is only the headline text and isn't unique enough on its own - see the worked example below) |

## Ingest it

```
python py/to_kdb.py                            # the whole archive (~204k rows, ~2 min)
python py/to_kdb.py --glob "2026/*.csv"        # just one year
python py/to_kdb.py --glob "2026/2026-09.csv"  # just one month (e.g. after a fresh scrape)
```

Every source month is authoritative for its own dates, so re-running the
same or a refreshed month's file just rewrites those date partitions -
safe to re-run after `econCalScraper` produces a new month. Options:

```
python py/to_kdb.py [--src-dir <econCalScraper/data>] [--glob <pattern>]
  [--db C:/data/calendar] [--stage-dir <path>] [--q <q.exe>] [--qhome <QHOME>]
  [--schema <schema_calendar.q>] [--table econCal] [--no-load] [--keep-stage]
```

Under the hood: `py/to_kdb.py` reads each CSV with the stdlib `csv`
module and rewrites every row into one combined `|`-delimited staging
file (no CSV quoting at all - fxStreet event text carries embedded
commas and, rarely, double quotes; `|` sidesteps that entirely rather
than needing a quote-aware reader, since the source never contains a
literal `|`), then runs `q/load_calendar.q` against it. That loader is
schema-driven exactly like `modules/ingest/yfinance/q/load_yfinance.q`:
the on-disk column order and the CSV parse-type string are both derived
from `econCal`'s definition in `schema_calendar.q` via `meta`, not
hard-coded.

## Query it

`cfg_proc/modules/calendar/hdb.json` fronts the archive with the generic
`hdb` role (port 5078) for gateway/qcon queries:

```
q initFromCfg.q -config ../cfg_proc/modules/calendar/hdb.json
```

```q
/ every HIGH-importance US release on one day
select time,event,actual,consensus,previous from econCal
  where date=2026.09.01, country=`US, importance=`HIGH

/ one event's own history, keyed on eventId (not `event` text alone -
/ see "Data" above)
eid:first exec eventId from select from econCal
  where date=2026.09.04, country=`US, event=`$"Nonfarm Payrolls";
select date,actual,consensus,previous from econCal where eventId=eid
```

# openQ/core

A lightweight, domain-generic kdb+ tick-database core: tickerplant &rarr; RDB/HDB
&rarr; gateway, plus the operational plumbing (logging, timers, IPC, connection
tracking, server discovery, query sandboxing) to run it.

## Layout

```
core/             tp/rdb/hdb/gw/cep/idb/eod/housekeeping/fh roles, config.q,
                  init.q (CLI-flag bootstrap), initFromCfg.q (JSON bootstrap)
core/utils/       log, timer, ipc, conn, servers, perm, gateway, logToTab
schemas/          schema.q (generic demo) + one schema_*.q per module/archive
cfg_proc/         one JSON config per role/module, for initFromCfg.q
modules/analytics/<name>/  spread, markout, primeFinance, report - each
                  paired with its own cep.q/simulator.q
modules/backtest/ backtest.q engine, candle.q patterns, run.q
modules/ingest/<name>/     feed-handler-fronted modules (massive,
                  massive_stocks); modules/ingest/yfinance/ is a separate
                  Python-only ingest, no cep.q - see its own README
modules/utils/<name>/      generator, hdb2tplog, replay - standalone libs
tests/sh/, tests/q/        acceptance tests and the scripts they drive
```

## Running it

```
./scripts/startup.sh       # tp+rdb+hdb+gw on 5010-5013, ./scripts/shutdown.sh to stop
```

Config-driven alternative (`cfg_proc/*.json`, no CLI-flag list):

```
q initFromCfg.q -config ../cfg_proc/rdb.json
```

- `./scripts/startupAllByModule.sh <name>` - one module by name
- `./scripts/startupAll.sh` - default pipeline + every module
- `./scripts/startupAllWithGen.sh` - same, with synthetic data flowing via `generator.q`

Each has a matching `shutdown*.sh`. A feed handler publishes into a TP with
`` `upd `` (async, classic tick.q); a CEP subscribes the same way an RDB does
and can itself be subscribed to (CEPs chain); a client queries via the
gateway: `neg[h] (`.oq.gw.query;`quote;`;sTime;eTime;`;`)`, then `h[]`.

**RDB active/standby pair**: every `rdb` is two processes on one config
(`-instance 1|2`) - only one is ever subscribed to the tickerplant.
`.oq.rdb.activate[]`/`.oq.rdb.standby[]` (plain IPC calls) promote/demote;
no automatic failover is wired in.

## Modules

Default flow: `fh -> tp -> cep -> rdb -> eod -> hdb` (`idb` pivots the rdb
pair on a timer rather than subscribing). `tp/rdb/idb/hdb` are
schema-agnostic; a module's only real code is its CEP (an analytics
library + handler registrations) and, optionally, its own feed handler.

| Module | Ports | Schema | What it does |
|---|---|---|---|
| `mon` | 5020 tp, 5021/5101 rdb, 5022 idb, 5023 hdb, 5024 cep, 5026 hk, 5066 eod\* | `schema_mon.q` | Central `logs` + host `pidstats` monitoring for every other process |
| `markout` | 5030 tp, 5031/5102 rdb, 5032 idb, 5033 hdb, 5034 cep, 5067 eod\* | `schema_markout.q` | Trade markout / order impact via `markOutImpact.q` |
| `massive` | 5018 fh, 5045 tp, 5049 cep, 5046/5105 rdb, 5047 idb, 5048 hdb, 5068 eod\* | `schema_efx.q` | Real vendor FX WebSocket feed &rarr; `fx_tick_massive`/`fx_m1_massive` |
| `spread` | 5055 tp, 5056/5103 rdb, 5057 idb, 5058 hdb, 5059 cep, 5069 eod\* | `schema_spread.q` | FX spread build-up/attribution via `spread.q` |
| `primeFinance` | 5070 tp, 5071/5104 rdb, 5072 idb, 5075 hdb, 5074 cep, 5076 eod\* | `schema_primefinance.q` | Securities-lending inventory/locate/borrow/recall/exposure |
| `report` | 5080 cep only\*\* | none | Unifies spread+markout+primeFinance into one Desk Risk & TCA view |

\* `eod` is a one-shot batch job, not a persistent server. \*\* `report`
has no tp/rdb/idb/hdb of its own. Every "rdb" cell is an active/standby
pair sharing one `rdb.json`. Run a module with
`./scripts/startupAllByModule.sh <name>`, or by hand in order
(`tp`&rarr;`cep`&rarr;`rdb -instance 1`&rarr;`rdb -instance 2`&rarr;`idb`&rarr;`hdb`)
via `q initFromCfg.q -config ../cfg_proc/modules/<name>/<role>.json`.

**`eod`** (`core/eod.q`) reads whatever `idb` has segmented to disk
(`-idbroot`) and promotes it into the dated HDB partition - a manual,
one-shot step, run only after `idb`'s final pivot for the day and never
twice for the same date. Two modules automate it via a `housekeeping`
process instead (`-hkscript` + `-hkfreq`): `eq_m1_yfinance` (08:30 UTC)
and `mon` (00:00 UTC), both calling `.oq.idb.eod[dt]` on the live `idb`
and gating on a marker file so a restart can't double-promote.

**`generator`** (`modules/utils/generator/generator.q`, no process role)
generates type-correct random rows for any `schemas/schema_*.q`, schema-blind.

**`hdb2tplog`** (`modules/utils/hdb2tplog/`, no process role) reads a table
back out of an on-disk HDB and writes it as a standard, replayable
tickerplant log - read-only against the source:

```
q modules/utils/hdb2tplog/hdb2tplog.q -hdb <efx-archive-root> -table fx_m1_massive \
  -log examples/data/fx_m1_massive.tplog -schema schemas/schema_efx.q -part 2025.12.31 -verify
```

## Desk Risk & TCA

`modules/analytics/report/deskRisk.q` combines spread/markout/primeFinance's
existing pure batch functions (unmodified) into one per-symbol view: quoted
spread cost, post-trade markout/impact, and financing fee/coverage.
Symbol-only, not client-level.

```
./scripts/startupAllByModule.sh spread
./scripts/startupAllByModule.sh markout
./scripts/startupAllByModule.sh primeFinance
./scripts/startupAllByModule.sh report
q modules/analytics/spread/simulator.q
q modules/analytics/markout/simulator.q
q modules/analytics/primeFinance/simulator.q
```

```
q)h:hopen `:localhost:5080
q)h "select from .report.latest"
```

All three simulators share one universe (`AAPL`,`TSLA`,`GME`,`NVDA`) with
`GME` deliberately worst on every pillar. `.report.latest`: `sym`,
`spreadCostBp`, `markoutBp`, `impactBp`, `financingFeeBp`, `shortQty`,
`locatedQty`, `coverage`, `bucket`. A symbol missing from one domain gets
nulls there, not dropped.

## Feed handlers

`core/fh.q` connects/reconnects to `-tpaddr` and loads a
deployment-supplied `-fhscript` for vendor-specific connect/parse/auth -
the same "core role + custom script" split as `-cepscript`:

```
q init.q -procType fh -name mf0 -port 5018 \
  -fhscript ../modules/ingest/massive/fh.q -apikey <key> -tpaddr :host:port
```

`modules/ingest/massive/fh.q` is a worked example against a real vendor
Forex WebSocket API. It uses kdb+'s native WebSocket client, which **the
free/unlicensed build this was developed against doesn't have** - so its
message-handling logic is written as a pure function of an already-received
frame and tested that way (`tests/sh/run_massive_feedhandler_test.sh`); on
a build with WebSocket support the same code just works, no changes needed.

## Integrating an existing HDB

`hdb` can front any existing on-disk partitioned kdb+ database:

1. Write a schema file (see `schemas/schema_efx.q`) stubbing each real
   table (empty, real columns) and redefining `.oq.schema.tables[]`.
2. `q init.q -procType hdb -hdbroot <path> -schema <file> -port <port>`
3. Optionally front it with a `gw` - a purely historical archive needs no RDB.

Read-only by construction - nothing under `core/` writes to an `-hdbroot`
unless an `rdb`/`idb` process is explicitly pointed at it. `schema_efx.q`
is a working example against a real, large on-disk EFX tick/bar archive.

## Backtesting

`modules/backtest/backtest.q` is a pure-batch strategy engine over
historical OHLC bars, decomposed into four independently-swappable
stages (modeled on QuantConnect LEAN's Algorithm Framework):

1. **Alpha** (`.bt.alphas.*`) - `smaCrossover`, `meanReversion`,
   `momentum` (also emits confidence), `candlePattern` (wraps `candle.q`'s
   32 TA-Lib-style patterns)
2. **Portfolio construction** (`.bt.portfolio.*`) - `direction` (default,
   full &plusmn;1) or `confidenceWeighted`
3. **Risk** (`.bt.risk.*`) - `none` (default), `maxPosition`, `maxDrawdown`
4. **Execution** (`.bt.execution.*`) - `immediate` (default, lag+hold) or
   `twap` (lag+phase-in)

`.bt.run[bars;pipeline;cfg]` only requires `pipeline[`alpha]`; the rest
default. `.bt.stats` gives `totalReturn`/`sharpe`/`maxDrawdown`/`hitRate`/
`numTrades`/`avgTurnover`.

```
q modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 -strategy sma -fastN 5 -slowN 20
q modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 \
  -strategy momentum -portfolio confweighted -risk maxdd -ddLimit 0.02 -execution twap -phaseIn 5
```

`candle.q` (32 patterns, ported from third-party `kdb_candle`) needed
several real fixes to run on this build at all (dyadic `max`/`min`,
scalar-only `$[cond;a;b]`, reserved-word locals) - all verified empirically.

## Monitoring & logging

`core/utils/logToTab.q` forwards every log message into a central `logs`
table over the same tp/rdb pipeline as tick data (a "mon" stack is just
another tp/rdb/hdb quartet against `schema_mon.q`):

```
system "l utils/logToTab.q";
.util.logToTab.connect[`:localhost:5020];
.util.logToTab.log[`WARN;`MY_W001;"message text"];
```

`logs` follows KX's logging banner (`timestamp sym level host pid handle
user mem code message`). `pidstats` is host-level CPU/memory, shipped by
`modules/mon/pidstat_poller.py` (Python, over qpython):

```
python3 modules/mon/pidstat_poller.py --host localhost --port 5020 --interval 5
```

## Tests

| Script | Covers |
|---|---|
| `run_pipeline_test.sh` | end-to-end tp/rdb/hdb/gw: publish, query pre/post-EOD, RDB flush |
| `run_cep_test.sh` | cep.q pub/sub chaining with a derived-table handler |
| `run_cep_analytics_test.sh` | spread.q/markOutImpact.q as plain libraries in a CEP |
| `run_idb_test.sh` | idb.q checkpoint/append/flush-notify/EOD-promote lifecycle |
| `run_efx_test.sh` | existing-HDB integration against a real EFX archive; read-only |
| `run_massive_feedhandler_test.sh` | massive/fh.q message parsing/mapping/batching |
| `run_logtotab_test.sh` | logToTab.q end-to-end into a mon TP/RDB |
| `run_report_test.sh` | report + deskRisk.q via `startupAllByModule.sh` |
| `run_backtest_test.sh` | backtest.q + run.q against the real EFX archive; read-only |
| `run_hdb2tplog_test.sh` | hdb2tplog.q export/replay round-trip |

`run_efx_test.sh`/`run_backtest_test.sh` self-skip if the EFX archive
(path set via the `EFX_ROOT` env var) isn't present. Logs land in
`tests/logs/`, except `run_report_test.sh` (`scripts/logs/bymod_*.log`).

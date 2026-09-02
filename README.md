# openQ/core

A lightweight, domain-generic kdb+ tick-database core: tickerplant &rarr; RDB/HDB
&rarr; gateway, with the operational plumbing (logging, timers, IPC, connection
tracking, server discovery, query sandboxing) needed to actually run it.

## Layout

```
modules/analytics/<name>/  general-purpose (not CEP- or schema-specific)
             analytics libraries a CEP handler can load and feed, each
             paired with the module's own cep.q/simulator.q: spread/
             spread.q (spread build-up/attribution), markout/
             markOutImpact.q (trade markout / order impact), primeFinance/
             primeFinance.q (securities-lending inventory/locate/borrow/
             recall) - see core/cep.q and "Tests" below. report/
             deskRisk.q unifies all three into one "Desk Risk & TCA" report.
modules/backtest/  backtest.q, a standalone strategy-backtesting engine
             over historical OHLC bars, candle.q (32-pattern candlestick
             recognition, wired in as an alpha model), run.q - see
             "Backtesting" below.
modules/ingest/<name>/  feed-handler-fronted modules (massive,
             massive_stocks): each pairs a vendor feed handler
             (-fhscript or a non-q script) with its own cep.q - see
             "Feed handlers" below. modules/ingest/yfinance/ is a
             different pattern: standalone Python scripts for the real
             eq_m1_yfinance/eq_d1_yfinance ingest, no cep.q - see its own
             README_eq_m1_yfinance.md.
modules/utils/<name>/  standalone utility scripts/libraries that aren't
             tp/rdb/idb/hdb/cep pipelines: generator (schema-blind
             random-data generation), hdb2tplog (HDB table -> tp log
             export), replay (paced tp-log replay into a live pipeline).
core/utils/  generic infra: log, timer, handlers (.z.p* hook chaining),
             start (CLI params), core (misc helpers), ipc, conn, servers,
             perm (query sandbox), gateway (async fan-out engine),
             logToTab (forwards log messages into a central logs table -
             see "Monitoring & logging" below)
schemas/schema.q   example generic schema: quote/trade tables (timestamp,sym first)
schemas/schema_efx.q  schema stubs for an existing on-disk EFX historical HDB -
                see "Integrating an existing HDB" below
schemas/schema_eq.q  schema stub for an existing on-disk equities HDB
                (C:/data/db1/eq): eq_d1_yfinance daily OHLCV bars for NYSE +
                Nasdaq. Read-only, same pattern as schema_efx.q. Load with
                cfg_proc/modules/eq/hdb.json (eq_hdb, port 5090).
schemas/schema_mon.q  schema for a central `logs` table and a `pidstats`
                host CPU/memory table - see "Monitoring & logging" below
schemas/schema_markout.q  trade/order/rate schema for the markout module
schemas/schema_spread.q  `spreadQuote` schema for the spread module
schemas/schema_primefinance.q  `inventory`/`locate`/`position`/`borrow`/
                `recall` schema for the primefinance module
core/tp.q       tickerplant (.u namespace): pub/sub, log write/rotate/replay
core/rdb.q      RDB: subscribes to a TP, replays missed ticks, flushes on demand
core/hdb.q      HDB: loads/reloads the on-disk partitioned database
core/save.q     EOD save-down: create/append checkpoints, read them back
                (.oq.save.readCheckpointed - shared by idb.q's own EOD and
                eod.q's standalone one), sorted stage-then-atomic-publish,
                and the low-level column read/write/append primitives
core/query.q    query builder: date-partition + time + sym where-clauses
core/gw.q       gateway routing: RDB vs HDB vs both, by time range
core/cep.q      generic CEP: subscribes to any .u.sub-speaking source, runs
                registered handlers per table, can itself publish derived
                output downstream (chainable)
core/idb.q      idb writer: an independent TP subscriber that checkpoints
                to disk on a timer, tells the RDB when it's safe to flush,
                and promotes the day's checkpoints to the real HDB at EOD
core/eod.q      standalone EOD promotion: no live tp/idb needed, just reads
                one idb writer's already-checkpointed segments off disk and
                promotes them - a one-shot batch job, not a server
core/housekeeping.q  timer-driven health checks (.oq.hk.checkTP etc.) plus
                .oq.hk.init - a small illustrative set
core/fh.q       generic feed handler: connects to (and reconnects to) the
                TP it republishes into, batches rows into a publish, and
                loads a deployment-supplied -fhscript for vendor-specific
                connect/parse/auth logic - see "Feed handlers" below
core/init.q     bootstrap: `q init.q -procType tp|rdb|hdb|gw|cep|idb|housekeeping|fh ...`
core/initFromCfg.q  alternative bootstrap: `q initFromCfg.q -config <path>`,
                reading name/port/schema/utilities/libraries/params from a
                JSON file - see "Config-driven bootstrap" below
core/config.q   CLI parameters each process role needs, with defaults
cfg_proc/       one JSON config per role, for initFromCfg.q
cfg_proc/modules/<name>/  JSON configs for one module's tp/rdb/idb/hdb/cep
modules/  custom code for every module, grouped thematically into
                analytics/, ingest/, backtest/, utils/ - see "Modules" below
tests/sh/       acceptance test scripts - see "Tests" below
tests/q/        q client/handler scripts the tests/sh/ scripts drive
tests/logs/     per-run logs written by tests/sh/ scripts (gitignored)
```

## Running it

```
./scripts/startup.sh
```

Launches tp+rdb+hdb+gw (ports 5010-5013) as background processes, keeps any
existing data under `examples/data/` (safe to rerun), logs to
`scripts/logs/`, PIDs in `scripts/logs/openq.pids`. Stop with
`./scripts/shutdown.sh`. Env overrides: `TP_PORT RDB_PORT HDB_PORT GW_PORT
DATA_DIR BMODE Q_BIN`.

Each process, run individually, is `q init.q -procType <role> -name <name>
-port <port> ...`. See `tests/sh/run_pipeline_test.sh` for a complete
working example. Per-role init lives in that role's own `.init[]`
(`tp.q`'s `.oq.tp.init`, and so on) - `init.q` itself only knows which
files a role needs to load. Useful params:

- tp: `-tplogdir <dir> -bmode 0|1` (0=no-latency, 1=batch)
- rdb: `-tpaddr :host:port -hdbroot <dir> -port1 <port> -port2 <port>
  -instance 1|2` - every rdb is an **active/standby pair** (see below):
  the same config is launched twice, once per `-instance`. Only instance
  1 subscribes to the tickerplant at startup - instance 2 comes up
  queryable but idle until `.oq.rdb.activate[]` is called on it.
- hdb: `-hdbroot <dir> -schema <path>` (`-schema` defaults to
  `../schemas/schema.q`; point it at a different schema - e.g.
  `../schemas/schema_efx.q` - to front a differently-shaped existing
  on-disk database; see "Integrating an existing HDB" below)
- gw: `-rdbaddr :host:port -hdbaddr :host:port`
- cep: `-srcaddr :host:port -cepscript <path> -tplogdir <dir> -bmode 0|1`
  (`-cepscript` defines output table(s) and registers handlers via
  `.oq.cep.addHandler[tab;fn;info]`; `-tplogdir` blank means no on-disk
  log for the CEP's own output, in-memory pub/sub only)
- idb: `-tpaddr :host:port -rdbaddr :host:port -rdbaddr2 :host:port
  -idbroot <dir> -hdbroot <dir> -checkpointfreq <timespan>` - subscribes
  to the TP independently of the query-serving RDB(s); every
  `-checkpointfreq` it writes what's buffered to `-idbroot`, then tells
  both configured RDBs it's safe to flush. `-rdbaddr2` is optional for a
  single-RDB deployment. `.oq.idb.eod[date]` promotes everything
  checkpointed plus whatever's still buffered into the real HDB.
- housekeeping: `-hkscript <path> -hkfreq <timespan>` (`-hkscript` defines
  a niladic `.oq.hk.run` composing `checkTP`/`checkRowCounts`/
  `checkHDBFresh` or similar; defaults to a 1-minute `-hkfreq`. See
  `tests/q/housekeeping_check.q`)
- standAlone (`cfg_proc/standAlone.json`): a second, independent
  `-hkscript` runner instance (port 5091) for running one particular
  one-off script on demand without touching `hk0`.

A feed handler publishes by connecting to the TP and calling `` `upd `` async
- the classic kdb+ tick.q convention. A CEP consumes the same way an RDB
does (`.u.sub`) and, since it exposes the same `.u.sub`/`.u.pub` protocol
for its own derived tables, can itself be subscribed to - CEPs chain. A
client queries via the gateway: `neg[h] (`.oq.gw.query;`quote;`;sTime;eTime;`;`)`,
then blocks on `h[]` for the (possibly RDB+HDB joined) reply.

### RDB active/standby pair

Every `rdb` is really two processes sharing one config, modeled on the
master/slave RDB pattern real kdb+tick deployments use - an RDB holding a
full trading day's ticks is memory- and query-load-heavy, and losing it
shouldn't mean losing live data. A deliberately smaller, static take on
that idea: two fixed instances, manual promote/demote rather than an
automatic orchestrator.

- **Only one instance is ever subscribed to the tickerplant.** Instance 1
  boots active; instance 2 boots standby - fully queryable, but not
  subscribed, so it never receives a row. `.oq.rdb.active` tracks which
  this instance currently is.
- **`.oq.rdb.activate[]`** promotes a standby to active - since it's this
  instance's first-ever connection, it replays every missed tplog segment
  before the live feed picks up.
- **`.oq.rdb.standby[]`** demotes an active instance - closes its
  tickerplant handle(s); the tickerplant's own disconnect cleanup removes
  it from `.u.w` for free.
- Both are callable over plain IPC from any client: `h(`.oq.rdb.activate;::)`/
  `h(`.oq.rdb.standby;::)`. There's no automatic failover trigger wired
  in - promoting instance 2 doesn't tell `gw`'s `-rdbaddr` to repoint;
  extending `core/gw.q` with an add/remove/switch-server verb set is the
  natural next step for that.
- `core/idb.q` notifies **every** configured RDB address on each
  checkpoint, not just one - harmless on whichever is standby, correct on
  whichever is active.

## Config-driven bootstrap

`core/initFromCfg.q` is an alternative to `init.q`'s CLI-flag style:

```
q initFromCfg.q -config ../cfg_proc/rdb.json
```

`cfg_proc/` has one JSON file per role, each shaped:

```json
{
  "procType": "rdb",
  "name": "rdb0",
  "port": 5011,
  "schema": "../schemas/schema.q",
  "utilities": ["utils/timer.q", "utils/handlers.q", "utils/conn.q", "utils/ipc.q", "utils/servers.q", "utils/perm.q"],
  "libraries": ["rdb.q", "utils/gateway.q", "query.q", "save.q"],
  "params": {"tpaddr": ":localhost:5010", "hdbroot": "../examples/data/hdb"}
}
```

A CLI flag with the same name as a JSON key still wins - the JSON only
fills in values the command line didn't provide. `schema`/`utilities`/
`libraries` are read once to drive what loads; `procType`/`name`/`port`
and everything under `params` merge into `.util.start.CLP`, read exactly
the way `init.q` would provide them.

`scripts/startupCfg.sh` is a config-driven sibling of `scripts/startup.sh`
(same tp/rdb/hdb/gw quartet, same PID file). Three more scripts, each with
a matching `shutdown*`, cover starting more than one pipeline:

- **`scripts/startupAllByModule.sh <name>`** starts one module by name
  (e.g. `./scripts/startupAllByModule.sh mon`) - whatever
  `cfg_proc/modules/<name>/*.json` files exist, in the right order.
  `shutdownAllByModule.sh <name>` stops it; PIDs in `openq-<name>.pids`.
- **`scripts/startupAll.sh`** starts the default pipeline plus every
  module at once. `shutdownAll.sh` stops it; PIDs in `openq-all.pids`.
  No synthetic data flows on its own.
- **`scripts/startupAllWithGen.sh`** is the same set, except every tp
  also gets a non-blank `-genFreq`, turning on
  `modules/utils/generator/generator.q`'s self-publish timer - real-
  looking (type-correct, not semantically real) random data flows within
  seconds. `shutdownAllWithGen.sh` stops it; PIDs in `openq-all-gen.pids`.

All three are independent of each other's pidfiles - safe to run
alongside any of them as long as ports don't overlap (running
`startupAll.sh`/`startupAllWithGen.sh` together would collide on every
port, so don't).

## Modules

A module is self-contained deployment-specific code built entirely on the
config-driven bootstrap above, without touching `core/`. Default flow:

```
fh -> tp -> cep -> rdb -> eod -> hdb
```

(`idb` pivots the `rdb` active/standby pair on its own timer rather than
subscribing anywhere in this flow - see core/idb.q's header.)

`fh` (not every module has one; see "Feed handlers" below) publishes into
`tp`. `tp.q`/`rdb.q`/`idb.q`/`hdb.q` are schema-agnostic, so pointing
`-schema` at a domain-specific file is enough - the only code a module
adds is genuinely custom to that domain, living in its CEP: whatever
analytics library it loads and what it does with incoming ticks. Every
module's CEP also relays every row unchanged via `.u.upd` alongside its
analytics, since `rdb` subscribes to the CEP rather than `tp` directly.
`idb` pulls the harvested rdb side's data over IPC on its own timer. `eod`
unions whatever `idb` has segmented to disk and promotes it into `hdb` - a
manual, one-shot step.

A module can add a satellite process alongside its pipeline (or instead of
one) - `massive` pairs a `core/fh.q` feed handler with its own pipeline. A
feed handler doesn't have to be q at all: `mon`'s `pidstat_poller.py`
publishes from a plain Python script over qpython IPC, no `core/` role
needed. A module doesn't have to be a running pipeline at all either -
`generator` is a plain utility library.

```
modules/.../<name>/      custom code for the module - q (a -cepscript or
                          -fhscript) or, for a non-q feed handler, whatever
                          language it's written in. Grouped by theme:
                          modules/analytics/<name>/ (markout, spread,
                          primeFinance, report), modules/ingest/<name>/
                          (massive, massive_stocks), modules/backtest/,
                          modules/utils/<name>/ (generator, hdb2tplog, replay)
cfg_proc/modules/<name>/ one JSON per q process the module runs -
                          tp/cep/rdb/idb/hdb/eod.json, plus fh.json for a
                          module with its own feed handler. One flat
                          folder per module name regardless of grouping.
```

Run a module in order, pointed at `cfg_proc/modules/<name>/`:

```
q initFromCfg.q -config ../cfg_proc/modules/mon/tp.json
q initFromCfg.q -config ../cfg_proc/modules/mon/cep.json
q initFromCfg.q -config ../cfg_proc/modules/mon/rdb.json -instance 1
q initFromCfg.q -config ../cfg_proc/modules/mon/rdb.json -instance 2
q initFromCfg.q -config ../cfg_proc/modules/mon/idb.json
q initFromCfg.q -config ../cfg_proc/modules/mon/hdb.json
```

`cep` needs to be up before `rdb` for its first connection to find a
source (recovers on its own via 30s reconnect timers otherwise). `idb`'s
start order doesn't matter, only that both `rdb` instances are up before
its first pivot. `scripts/startupAllByModule.sh <name>` does all of this
in order for you.

Each full-pipeline module claims its own block of five ports:

| Module | Ports | Schema | Custom code |
|---|---|---|---|
| `mon` | 5020 tp, 5021/5101 rdb (active/standby), 5022 idb, 5023 hdb, 5024 cep, 5026 housekeeping, 5066 eod\* | `schemas/schema_mon.q` (`logs`, `pidstats`) | `modules/mon/cep.q`, `modules/mon/eod_housekeeping.q`, `modules/mon/pidstat_poller.py` |
| `markout` | 5030 tp, 5031/5102 rdb (active/standby), 5032 idb, 5033 hdb, 5034 cep, 5067 eod\* | `schemas/schema_markout.q` | `modules/analytics/markout/cep.q` |
| `massive` | 5018 fh, 5045 tp, 5049 cep, 5046/5105 rdb (active/standby), 5047 idb, 5048 hdb, 5068 eod\* | `schemas/schema_efx.q` (`fx_tick_massive`, `fx_m1_massive`) | `modules/ingest/massive/fh.q`, `modules/ingest/massive/cep.q` |
| `spread` | 5055 tp, 5056/5103 rdb (active/standby), 5057 idb, 5058 hdb, 5059 cep, 5069 eod\* | `schemas/schema_spread.q` (`spreadQuote`) | `modules/analytics/spread/cep.q` |
| `primeFinance` | 5070 tp, 5071/5104 rdb (active/standby), 5072 idb, 5075 hdb, 5074 cep, 5076 eod\* | `schemas/schema_primefinance.q` (`inventory`,`locate`,`position`,`borrow`,`recall`) | `modules/analytics/primeFinance/cep.q` |
| `report` | 5080 cep only\*\* | none | `modules/analytics/report/cep.q` |

\* `eod` is a one-shot batch job - its port is only bound for the few
seconds it runs. \*\* `report` has no tp/rdb/idb/hdb of its own - see
"Desk Risk & TCA" below. Every "rdb" cell is an active/standby pair (the
second port is the standby's) sharing one `rdb.json`.

`massive`'s `fh` (port 5018) targets `massive_tp` (`:localhost:5045`) by
default - point `tpaddr` at `:localhost:5010` instead to feed the default
pipeline.

Every module runs *one* `idb` process against its own `rdb` pair, driving
its pivot on a timer and writing numbered segments (`0`,`1`,`2`,... under
`-idbroot`) rather than a single date-keyed checkpoint.

**`eod`** (`core/eod.q`, `cfg_proc/modules/<name>/eod.json`) is a
standalone promotion process - no rdb pair, no in-memory buffer. It reads
whichever segments `idb` has written (`.oq.save.readSegments`, unioning
every `0,1,2,...` segment under `-idbroot`) and promotes them through the
same sorted/enumerated/attributed/atomic-publish pipeline every EOD path
uses:

```
q initFromCfg.q -config ../cfg_proc/modules/mon/eod.json
```

Runs once for `-eodDate` (`.z.d` if not given) and exits - not part of
`scripts/startupAll*.sh`'s always-on set. Two modules wire an automatic
nightly promote instead, via a dedicated `housekeeping` process
(`-hkscript` pointed at an `eod_housekeeping.q`, 1-minute `-hkfreq`):
`eq_m1_yfinance` (`modules/ingest/yfinance/eod_housekeeping.q`, fires past
`-eodTriggerTime` 08:30:00 UTC, promotes `.z.d`) and `mon`
(`modules/mon/eod_housekeeping.q`, `-eodTriggerTime` 00:00:00 UTC,
promotes `.z.d - 1`). Both call `.oq.idb.eod[dt]` over IPC on the live
`idb` and gate on a marker file under `-hdbroot/.eod_markers/<date>` so a
restart can't double-promote. Run `eod` only after `idb`'s final pivot
for the day, and never twice for an already-published date - nothing
coordinates that, and a second promote collides with `.oq.save.publish`'s
atomic rename.

**`mon`** ingests two independent streams (see "Monitoring & logging"
below): `logs` (via `core/utils/logToTab.q`, with an analytics handler
tracking WARN/ERROR/FATAL counts per process and a 5-minute summary
timer) and `pidstats` (via `modules/mon/pidstat_poller.py`, relay only).
`modules/mon/cep.q` registers the generic per-table relay on every table
plus that one analytics handler. Its `housekeeping` process promotes each
completed UTC day at 00:00 UTC.

**`markout`** ingests real `trade`/`order`/`rate` streams into
`modules/analytics/markout/markOutImpact.q`. `modules/analytics/markout/cep.q`
relays every table plus handlers: `trade`&rarr;`.markout.onTrade`,
`order`&rarr;`.impact.onOrder`, `rate`&rarr;both `.markout.onRate` and
`.impact.onBook`, plus a 1-minute `sweepPending` timer on both libraries
to stop a dead symbol or feed gap leaking pending rows forever.

**`massive`** is both a feed handler and its own pipeline (`fh -> tp ->
cep -> rdb/idb -> hdb`, same order as every module). Its `fh`
(`modules/ingest/massive/fh.q` - see "Feed handlers" below) talks to a
vendor Forex WebSocket API and republishes into `massive_tp`; the rest is
the default `tp.q`/`rdb.q`/`idb.q`/`hdb.q`/`cep.q` pointed at
`schemas/schema_efx.q`'s `fx_tick_massive`/`fx_m1_massive` tables instead
of the generic default, matching a real historical EFX archive's shape
(see "Integrating an existing HDB" below). The vendor's two channels map
one-to-one: real-time NBBO quotes (`"C"`) &rarr; `fx_tick_massive`,
per-minute OHLCV aggregates (`"CA"`) &rarr; `fx_m1_massive`. Every CEP in
this repo runs with `tplogdir:""` - the tplog only exists at `tp`, the
single durable source of truth; a disconnected subscriber catches up via
`tp`'s own log on reconnect, and the 30s reconnect timer keeps any gap
short. (This needed one `core/tp.q` fix: `.u.tick` used to leave
`.u.j`/`.u.L` undefined for a blank `-tplogdir`, silently breaking new
subscriptions - now always initialized to null.)

**`spread`** wraps `modules/analytics/spread/spread.q` (FX spread build-up
& attribution across seven named components). `schemas/schema_spread.q`'s
`spreadQuote` table matches `.spread.quote`'s canonical input shape
column-for-column. `modules/analytics/spread/cep.q` relays every table
plus one handler: every quote feeds `.spread.onQuote`, plus a 1-minute
timer logging the currently-widest keys - no pending-row sweep needed,
since spread attribution needs no future data to resolve.

**`primeFinance`** wraps `modules/analytics/primeFinance/primeFinance.q`,
a securities-lending domain model: `inventory -> locate -> reservation ->
borrow -> position coverage -> recall -> buy-in risk -> financing
economics`. Unlike `markout`/`spread`, it keeps real stateful books
(`.prime.inventory`/`reservations`/`locates`/`positions`/`borrows`)
accumulating across every event. `modules/analytics/primeFinance/cep.q`
relays every table plus a stateful handler per table folding it into the
matching book, and a 1-minute `sweep` timer expiring stale
locates/reservations. Allocation is a deterministic weighted-scoring
function (`.prime.cfg`: fee/scarcity/recall-risk/counterparty-risk/
priority) over available inventory - a thin/expensive-to-borrow name
allocates worse than a liquid large-cap under identical demand (see
`modules/analytics/primeFinance/simulator.q`). Coverage
(`.prime.positionCoverage`: `shortQty`/`locatedQty`/`coverage`/`bucket`)
is a pure batch function of the current books, callable any time.

**`report`** is a single always-on process (no schema, no pipeline) that,
on a 1-minute timer, pulls the raw state each of `spread`/`markout`/
`primeFinance` holds and recomputes a unified per-symbol report via
`modules/analytics/report/deskRisk.q`, served off `.report.latest`. See
"Desk Risk & TCA" below.

**`generator`** (`modules/utils/generator/generator.q`, no `cfg_proc/`
entry, not a process role) generates type-correct random data for *any*
`schemas/schema_*.q` file - schema-blind, reading table set off
`.oq.schema.tables[]` and column types off `meta`.
`.gen.forSchema["../schemas/schema_x.q";n]` returns `n` random rows per
table; `.gen.publish[tpAddr;schemaFile;n]` generates and publishes them
into a live tp in one call.

**`backtest`** is unrelated to any module above - a plain script
(`modules/backtest/run.q`), not a pipeline. See "Backtesting" below.

**`hdb2tplog`** (same plain-script shape, no `cfg_proc/` entry) reads a
table back out of an on-disk database and writes it as a standard
tickerplant log - replayable via `-11!` + `upd:insert`, or by pointing a
fresh `rdb.q`/`idb.q` at it, or dropping it into a `-tplogdir`. Strictly
read-only against `-hdb`:

```
q modules/utils/hdb2tplog/hdb2tplog.q -hdb C:/data/db1/efx -table fx_m1_massive \
  -log examples/data/fx_m1_massive.tplog -schema schemas/schema_efx.q \
  -part 2025.12.31 -verify
```

Partitioned tables are read one partition at a time (peak memory bounded
by the largest partition), ordered by `timestamp`, with the virtual
partition column dropped. `-batch 1` writes one `upd` per row. `-part`/
`-lastn` restrict which partitions export. Also loadable as a library.
Covered by `tests/sh/run_hdb2tplog_test.sh`.

## Desk Risk & TCA

`modules/analytics/report/deskRisk.q` unifies `spread`/`markout`/
`primeFinance`'s existing pure batch functions - unmodified - into one
per-symbol "trading desk risk & TCA" view: what it costs to trade a name
(`spread`), how the market moved against the desk afterward
(`markout`/`impact`), and whether the resulting short position can be
financed (`primeFinance`). Symbol-only, not client-level - none of
`spread`/`markout`'s wire schemas carry a client dimension.

`modules/analytics/report/cep.q` is the only thing that knows where each
module's data lives; `deskRisk.q` itself takes already-fetched tables as
plain arguments, no IPC of its own. `spread`/`markout`'s RDBs only hold
what hasn't been checkpointed-and-flushed yet, so `report` merges live RDB
data with whatever's already checkpointed rather than querying the RDB
alone (which would make numbers flicker to nothing every couple of
minutes). `primeFinance`'s state is read straight off its CEP - never
flushed, no merge needed.

Run all three modules and see one coherent report:

```
./scripts/startupAllByModule.sh spread
./scripts/startupAllByModule.sh markout
./scripts/startupAllByModule.sh primeFinance
./scripts/startupAllByModule.sh report
q modules/analytics/spread/simulator.q
q modules/analytics/markout/simulator.q
q modules/analytics/primeFinance/simulator.q
```

then query the live report:

```
q)h:hopen `:localhost:5080
q)h "select from .report.latest"
```

All three simulators publish against the same shared universe
(`AAPL`,`TSLA`,`GME`,`NVDA`), with `GME` deliberately given the worst
economics across every pillar, so the report tells one coherent story.

`.report.latest` columns:

| Column | From | Meaning |
|---|---|---|
| `sym` | all | the symbol |
| `spreadCostBp` | `spread` | weighted-average quoted spread, in bp |
| `markoutBp` | `markout` | trade markout at the 5-minute mark, in bp |
| `impactBp` | `markout` | order impact at the 60-second mark, in bp |
| `financingFeeBp` | `primeFinance` | qty-weighted average borrow fee, in bp |
| `shortQty`, `locatedQty`, `coverage`, `bucket` | `primeFinance` | aggregate short exposure, coverage ratio, and `FULL`/`PARTIAL`/`AT_RISK`/`UNLOCATED` classification |

A symbol missing from one domain shows nulls in that domain's columns
rather than being dropped - the row set is every symbol seen anywhere.

## Feed handlers

A feed handler publishes ticks into a TP from an outside vendor source.
`core/fh.q` connects (and reconnects) to `-tpaddr`, exposes
`.oq.fh.publish[tab;rows]` to batch and republish rows, and loads a
deployment-supplied `-fhscript` for vendor-specific connect/parse/auth -
the same "core role + custom script" split `-cepscript` uses:

```
q init.q -procType fh -name mf0 -port 5018 \
  -fhscript ../modules/ingest/massive/fh.q -apikey <key> -tpaddr :host:port
```

`modules/ingest/massive/fh.q` is a worked example against a real vendor
Forex WebSocket API (Polygon-style: connect &rarr; `status:connected`
&rarr; auth &rarr; `status:auth_success` &rarr; subscribe &rarr; batched
JSON event arrays), subscribed to real-time NBBO quotes (`"C"`) and
per-minute OHLCV aggregates (`"CA"`) by default. Vendor-specific CLI
params (`-apikey`/`-wsurl`/`-channels`) are registered by the `-fhscript`
itself.

It uses kdb+'s native WebSocket client (`hopen` on `ws(s)://`, `.z.ws` as
the callback) - **the free/unlicensed build this was developed against
doesn't have it** (`hopen` on any `ws://`/`wss://` target fails with
`` 'domain ``/`` 'type ``). Because of that, the message-handling logic is
written as a pure function of an already-received text frame, independent
of the transport - `tests/sh/run_massive_feedhandler_test.sh` calls
`.z.ws` directly with the vendor docs' sample messages and confirms
correctly-mapped rows land on the RDB. On a build with WebSocket support,
the same code makes the real connection with no changes needed.

One gotcha: kdb+'s JSON parser (`.j.k`) returns short strings
(single-character ones especially) as char atoms, not symbols - every
field compared against or used as a symbol goes through an explicit
`` `$ `` cast first. The two channels' field naming also isn't consistent
with each other (`p` vs `pair` for the currency pair); aggregates have no
per-bar trade count, so `fx_m1_massive`'s `transactions` is null for
live-ingested rows, with `source` tagged `` `massive `` to distinguish
from the historical archive that otherwise populates that table.

## Integrating an existing HDB

openQ's `hdb` role can front any existing on-disk partitioned kdb+
database, not just data openQ itself wrote - `.oq.hdb.loadHDB` is just
`system"l "` against whatever root you point it at, and `.oq.query.query`
builds its column list from `cols[table]` at query time. To wire one in:

1. Write a schema file (see `schemas/schema_efx.q`) declaring each
   existing table as an empty stub with real column names/types, and
   redefining `.oq.schema.tables[]` to that DB's table list.
2. Start an HDB against it: `q init.q -procType hdb -hdbroot <path> -schema
   <your-schema-file> -port <port>`.
3. Optionally front it with a gateway (`-hdbaddr :host:port`) - the
   gateway's routing already sends anything ending before today to
   HDB-only, so a purely historical archive needs no RDB.

Read-only by construction: nothing under `core/` calls a
save/checkpoint/EOD function against an `-hdbroot` unless an `rdb`/`idb`
process's *own* `-hdbroot`/`-idbroot` is explicitly wired at it. `massive`
does exactly that deliberately, for its own separate `-hdbroot`, so its
live-ingested data matches the real archive's shape while the archive
itself stays untouched. `schemas/schema_efx.q` is a working example
against a real, large (tens of millions of rows/day, 2009-2026) on-disk
EFX tick/bar archive across two vendor feeds.

## Backtesting

`modules/backtest/backtest.q` is a small strategy-backtesting engine over
historical OHLC bars - pure batch functions, no IPC, no live component.
Needs any bar table shaped `timestamp,sym,open,high,low,close` -
`modules/backtest/run.q` feeds it real 1-minute FX bars off the EFX
archive (`fx_m1_massive`), but the engine itself doesn't care where bars
came from.

A strategy decomposes into four independently-swappable stages, modeled
on QuantConnect's **LEAN** Algorithm Framework
(`IAlphaModel`/`IPortfolioConstructionModel`/`IRiskManagementModel`/
`IExecutionModel`) - signal generation, position sizing, a risk overlay,
and execution style are each independently overridable. Unlike LEAN's
event-driven version, this engine only runs historical batch analysis, so
each stage is a plain column-in/column-out q function over the whole bars
table at once. LEAN's universe-selection stage has no analogue here -
this engine backtests one symbol at a time.

**`.bt.run[bars;pipeline;cfg]`** runs the pipeline: `pipeline` is a dict,
only `` `alpha`` is required, the rest fall back to defaults
(`.bt.pipelineDefaults`). `alpha[bars]` &rarr; normalized into an insight
dict (`` `direction`` required, `` `confidence`` optional, default `1f`)
&rarr; `portfolio[bars;insight;cfg]` sizes it &rarr;
`risk[bars;rawPos;cfg]` can override/clip &rarr;
`execution[bars;riskedPos;cfg]` turns the target into the position
actually held. Transaction cost (`cfg[\`costBp]`) applies once, centrally,
to whatever execution produces. Result: `bars` augmented with every
stage's output (`direction`,`confidence`,`rawPos`,`riskedPos`,`pos`,
`ret`,`netRet`,`equity`).

**`.bt.stats[btResult;cfg]`** summarizes: `totalReturn`, `sharpe`
(annualized via `cfg[\`barsPerYear]`), `maxDrawdown`, `hitRate`,
`numTrades`, `avgTurnover`.

### The four stages

1. **Alpha** (`.bt.alphas.*`, `{[bars] -> direction column or
   `` `direction`confidence`` dict}`):
   - `smaCrossover[bars;fastN;slowN]` - trend-following moving-average cross.
   - `meanReversion[bars;lookback;zEntry]` - fades a rolling z-score.
   - `momentum[bars;lookback]` - emits confidence too: direction is the
     sign of the rate of change, confidence its magnitude (capped at 1).
   - `candlePattern[bars;pat]` - wraps `modules/backtest/candle.q` (32
     TA-Lib-style patterns, `pat` from `` .candle.patternNames ``) as an
     alpha, firing for exactly the bar the pattern is detected on.
2. **Portfolio construction** (`.bt.portfolio.*`):
   - `direction` (**default**) - full &plusmn;1 sizing, ignores confidence.
   - `confidenceWeighted` - `direction*confidence`.
3. **Risk management** (`.bt.risk.*`) - an overlay applied after sizing:
   - `none` (**default**) - pass-through.
   - `maxPosition[bars;pos;cfg]` (`cfg[\`maxAbsPos]`) - clips to &plusmn;max.
   - `maxDrawdown[bars;pos;cfg]` (`cfg[\`ddLimit]`) - forces flat once the
     position's own hypothetical equity curve breaches `ddLimit`, resumes
     on a new high.
4. **Execution** (`.bt.execution.*`):
   - `immediate` (**default**) - delays the target by `cfg[\`lag]` bars
     (0-filled at the start), holds it fully.
   - `twap[bars;targetPos;cfg]` (`cfg[\`phaseIn]`) - lags first, then
     phases toward the target via a `phaseIn`-bar moving average of the
     lagged target.

Writing a strategy means writing one function matching one of these four
shapes; the other three keep their defaults.

Run it (no other process needed - the archive is loaded directly,
read-only):

```
q modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 -strategy sma -fastN 5 -slowN 20
q modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 -strategy meanrev -lookback 30 -zEntry 1.5
q modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 -strategy candle -pattern engulfing
```

or override every stage at once:

```
q modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 \
  -strategy momentum -lookback 15 -portfolio confweighted \
  -risk maxdd -ddLimit 0.02 -execution twap -phaseIn 5
```

`-efxroot` (default `C:/data/db1/efx`), `-sym`, `-sDate`/`-eDate`,
`-costBp`, `-lag`, `-barsPerYear` always apply; `-strategy
sma|meanrev|momentum|candle` picks the alpha; `-portfolio
direction|confweighted` picks sizing; `-risk none|maxpos|maxdd` picks the
overlay; `-execution immediate|twap` picks the fill style. Prints the
stats dict plus the last few bars of the augmented trace.

### Candlestick patterns (`modules/backtest/candle.q`)

A 32-pattern TA-Lib-style recognition library (13 single-candle, 7
two-candle, 12 three-candle), ported from the third-party `kdb_candle`
project - didn't run as committed upstream; every fix was found and
verified empirically against this build (dyadic `max`/`min` don't work
here, `$[cond;a;b]` needs a scalar `cond` not a vector, several reserved-
word/scoping issues). `.candle.functions[pat]` runs one pattern;
`.candle.scan.all[bars]`/`.candle.signals[bars;patterns]` scan several at
once; `.candle.meta` carries each pattern's direction category, candle
count, and TA-Lib category. See `.bt.alphas.candlePattern` above for how
it plugs into the backtest pipeline.

## Monitoring & logging

`core/utils/logToTab.q` sends every log message to a central `logs` table
too, over the same tp/rdb pipeline as tick data. A "mon" stack is just
another tp/rdb/hdb quartet against `schemas/schema_mon.q`:

```
q init.q -procType tp  -name mon_tp  -port 5020 -schema ../schemas/schema_mon.q -tplogdir <dir>
q init.q -procType rdb -name mon_rdb -port 5021 -tpaddr :localhost:5020 -hdbroot <dir> -schema ../schemas/schema_mon.q
```

Any other process loads the library and connects:

```
system "l utils/logToTab.q";
.util.logToTab.connect[`:localhost:5020];
.util.logToTab.log[`WARN;`MY_W001;"message text"];
```

`.util.logToTab.log` still writes locally via `.util.log.memEx`, then also
async-publishes as one row into the mon TP's `logs` table (flat value
tuple, tick.q convention). A dropped mon connection retries on a 30s
timer like every other upstream connection in this repo.

`logs` follows KX's "Logging Best Practices" banner: `timestamp sym level
host pid handle user mem code message` - `sym` holds the publishing
process's `-name`. (Named `logs`, not `log` - `log` is a reserved q
keyword.)

`pidstats` is host-level CPU/memory monitoring - `modules/mon/
pidstat_poller.py` polls Linux's `pidstat` and streams a merged row per
`(host,pid)` into `mon_tp` over `qpython`:

```
python3 modules/mon/pidstat_poller.py --host localhost --port 5020 --interval 5
```

Ships a row for every process `pidstat` reports, not just openQ's -
`sym`/`procType`/`port` populate only for a direct `init.q` invocation;
`command` always has the full command line either way.

The `mon` HDB root (`C:/data/db1/mon`) carries all monitoring tables
together, including an older table-health archive
(`tableHealth`/`tableHealthTick`, written by
`examples/scripts/05_table_health_scan.q`) written over a different date
range - so `core/hdb.q`'s load step is `\l` &rarr; `.Q.chk` &rarr; `\l`
(standard kx `tick/hdb.q` pattern), backfilling empty splays for any table
missing from a partition and re-registering the newly-stubbed tables.

## Tests

| Script | Covers |
|---|---|
| `run_pipeline_test.sh` | end-to-end tp/rdb/hdb/gw: publish, query pre/post-EOD, RDB flush |
| `run_cep_test.sh` | cep.q pub/sub chaining with a derived-table handler |
| `run_cep_analytics_test.sh` | spread.q/markOutImpact.q loaded as plain libraries into a CEP, ingesting live ticks |
| `run_idb_test.sh` | idb.q checkpoint/append/flush-notify/EOD-promote lifecycle, parted attribute on sym |
| `run_efx_test.sh` | existing-HDB integration against a real EFX archive; read-only; self-skips if `EFX_ROOT` isn't present |
| `run_massive_feedhandler_test.sh` | massive/fh.q message parsing/mapping/batching, via the vendor docs' sample messages |
| `run_logtotab_test.sh` | logToTab.q: mon TP+RDB, connect, log INFO/ERROR, confirm banner fields land correctly |
| `run_report_test.sh` | report module + deskRisk.q end-to-end via `startupAllByModule.sh`; structural checks (all symbols present, GME worse than AAPL on every pillar) |
| `run_backtest_test.sh` | backtest.q + run.q against the real EFX archive; read-only; self-skips if absent |
| `run_hdb2tplog_test.sh` | hdb2tplog.q export/replay round-trip |

Logs from the first several land in `tests/logs/`; `run_report_test.sh`
starts real module processes via `scripts/startupAllByModule.sh`, so its
logs land in `scripts/logs/bymod_*.log`. `run_backtest_test.sh` starts no
processes - output goes to `tests/logs/backtest_{sma,meanrev}.log`.

# openQ/core

A lightweight, domain-generic kdb+ tick-database core: tickerplant &rarr; RDB/HDB
&rarr; gateway, with the operational plumbing (logging, timers, IPC, connection
tracking, server discovery, query sandboxing) needed to actually run it.

## Layout

```
modules/analytics/<name>/  general-purpose (not CEP- or schema-specific)
             analytics libraries a CEP handler can load and feed, each
             paired with the module's own cep.q/simulator.q in the same
             directory: spread/spread.q (spread build-up/attribution),
             markout/markOutImpact.q (trade markout / order impact), and
             primeFinance/primeFinance.q (securities-lending inventory/
             locate/borrow/recall) - see core/cep.q and the "Tests"
             section below. report/deskRisk.q unifies all three into one
             per-symbol "Desk Risk & TCA" report - see "Desk Risk & TCA"
             below.
modules/backtest/  backtest.q, a standalone strategy-backtesting engine
             over historical OHLC bars with no CEP/live component at all,
             candle.q (a 32-pattern candlestick recognition library
             wired in as one of backtest.q's alpha models), and run.q,
             the script that runs both against a real archive - see
             "Backtesting" below.
modules/ingest/<name>/  feed-handler-fronted modules (massive,
             massive_stocks): each pairs a vendor-specific
             feed handler (-fhscript or a non-q script) with its own
             cep.q - see "Feed handlers" below. (modules/ingest/yfinance/
             is a different pattern: several standalone Python scripts for
             the real eq_m1_yfinance/eq_d1_yfinance ingest, no cep.q - see
             its own README_eq_m1_yfinance.md.)
modules/utils/<name>/  standalone utility scripts/libraries that aren't
             tp/rdb/idb/hdb/cep pipelines at all - generator (schema-blind
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
                (C:/data/db1/eq): `eq_d1_yfinance` daily OHLCV bars for NYSE +
                Nasdaq (date-partitioned, no timestamp column). Read-only,
                same pattern as schema_efx.q. Load with
                cfg_proc/modules/eq/hdb.json (eq_hdb, port 5090).
schemas/schema_mon.q  schema for a central `logs` table (see logToTab.q
                above) and a `pidstats` host CPU/memory table - see
                "Monitoring & logging" below
schemas/schema_markout.q  trade/order/rate schema for the markout module -
                see "Modules" below
schemas/schema_spread.q  `spreadQuote` schema for the spread module,
                matching modules/analytics/spread/spread.q's own input
                shape - see "Modules" below
schemas/schema_primefinance.q  `inventory`/`locate`/`position`/`borrow`/
                `recall` schema for the primefinance module - see
                "Modules" below
core/tp.q       tickerplant (.u namespace): pub/sub, log write/rotate/replay
core/rdb.q      RDB: subscribes to a TP, replays missed ticks, flushes on demand
core/hdb.q      HDB: loads/reloads the on-disk partitioned database
core/save.q     EOD save-down: create/append checkpoints, read them back
                (.oq.save.readCheckpointed - shared by idb.q's own EOD and
                eod.q's standalone one), sorted stage-then-atomic-publish,
                and the low-level column read/write/append primitives
                both idb.q and eod.q build on
core/query.q    query builder: date-partition + time + sym where-clauses
core/gw.q       gateway routing: RDB vs HDB vs both, by time range
core/cep.q      generic CEP: subscribes to any .u.sub-speaking source, runs
                registered handlers per table, can itself publish derived
                output downstream (chainable) by reusing tp.q's .u mechanics
core/idb.q      idb writer: an independent TP subscriber that checkpoints
                to disk on a timer, tells the RDB when it's safe to flush,
                and promotes the day's checkpoints to the real HDB at EOD
core/eod.q      standalone EOD promotion: no live tp/idb needed, just reads
                one idb writer's already-checkpointed segments off disk and
                promotes them - a one-shot batch job, not a server; see
                "Modules" below
core/housekeeping.q  timer-driven health checks (.oq.hk.checkTP etc.) plus
                .oq.hk.init - a small illustrative set, not the exhaustive
                suite a production deployment would want
core/fh.q       generic feed handler: connects to (and reconnects to) the
                TP it republishes into, batches rows into a publish, and
                loads a deployment-supplied -fhscript for the vendor-specific
                connect/parse/auth logic - see "Feed handlers" below
core/init.q     bootstrap: `q init.q -procType tp|rdb|hdb|gw|cep|idb|housekeeping|fh ...`
core/initFromCfg.q  alternative bootstrap: `q initFromCfg.q -config <path>`,
                reading name/port/schema/utilities/libraries/params from a
                JSON file (see cfg_proc/) instead of a long flag list -
                see "Config-driven bootstrap" below
core/config.q   CLI parameters each process role needs, with defaults
cfg_proc/       one JSON config per role, for initFromCfg.q - see
                "Config-driven bootstrap" below
cfg_proc/modules/<name>/  JSON configs for one module's tp/rdb/idb/hdb/cep -
                see "Modules" below (still one flat folder per launchable
                module, by launch name - independent of how the module's
                own code is grouped under modules/ below)
modules/  custom code for every module (typically just a -cepscript or
                -fhscript), grouped thematically into analytics/,
                ingest/, backtest/, and utils/ subdirectories rather than
                one folder per module at the top level - see "Modules"
                below and "Feed handlers" below
tests/sh/       acceptance test scripts (q init.q, publish, query, verify) -
                see "Tests" below
tests/q/        q client/handler scripts the tests/sh/ scripts drive
tests/logs/     per-run logs written by tests/sh/ scripts (gitignored)
```

## Running it

The easiest way to start the whole platform (tp+rdb+hdb+gw) is:

```
./scripts/startup.sh
```

It launches all four roles as background processes on ports 5010-5013,
keeps any existing data under `examples/data/` (safe to rerun), and writes
logs to `scripts/logs/`. It records each process's PID in
`scripts/logs/openq.pids`. Stop the platform with:

```
./scripts/shutdown.sh
```

which reads that PID file, stops each process (falling back to a forced
kill if needed), and removes the PID file. Override startup ports/paths via
env vars: `TP_PORT RDB_PORT HDB_PORT GW_PORT DATA_DIR BMODE Q_BIN`.

Each process, run individually, is `q init.q -procType <role> -name <name>
-port <port> ...`. See `tests/sh/run_pipeline_test.sh` for a complete working
example that starts all four roles from a clean slate, publishes sample
ticks, queries through the gateway, and runs an EOD save-down. `init.q`
itself only knows which files a role needs to load - the actual startup
sequence for each role lives in that role's own file as `.init[]` (`tp.q`'s
`.oq.tp.init`, `rdb.q`'s `.oq.rdb.init`, and so on for `hdb`/`gw`/`cep`/
`idb`/`housekeeping`), reading whatever CLI params it needs straight
from `.util.start.CLP` - `init.q` never needs to change just because a
role's own startup sequence does. Useful params:

- tp: `-tplogdir <dir> -bmode 0|1` (0=no-latency, 1=batch)
- rdb: `-tpaddr :host:port -hdbroot <dir> -port1 <port> -port2 <port>
  -instance 1|2` - every rdb is an **active/standby pair**, not a single
  process (modeled on the master/slave RDB pattern real kdb+ deployments
  use for this - see "RDB active/standby pair" below): the same config
  is launched twice, once per `-instance`, and
  `.util.start.resolveInstancePort` (`core/utils/start.q`) picks
  `-port1`/`-port2` apart and appends `_1`/`_2` to `-name` so the two
  register as distinct gateway servers. Only instance 1 subscribes to
  the tickerplant at startup - instance 2 comes up queryable but idle
  until something calls `.oq.rdb.activate[]` on it.
- hdb: `-hdbroot <dir> -schema <path>` (`-schema` defaults to
  `../schemas/schema.q`, relative to `core/`; point it at a different
  schema file - e.g. `../schemas/schema_efx.q` - to run an HDB against a
  differently-shaped existing on-disk database instead of openQ's own demo
  data; see "Integrating an existing HDB" below)
- gw: `-rdbaddr :host:port -hdbaddr :host:port`
- cep: `-srcaddr :host:port -cepscript <path> -tplogdir <dir> -bmode 0|1`
  (`-cepscript` is a q script defining any output table(s) and registering
  handlers via `.oq.cep.addHandler[tab;fn;info]` before the CEP subscribes
  to its source; `-tplogdir` is optional - blank means no on-disk log for
  the CEP's own derived output, in-memory pub/sub only)
- idb: `-tpaddr :host:port -rdbaddr :host:port -rdbaddr2 :host:port
  -idbroot <dir> -hdbroot <dir> -checkpointfreq <timespan>`
  (subscribes to the TP independently of the query-serving RDB(s) named
  by `-rdbaddr`/`-rdbaddr2`; every `-checkpointfreq` it writes what's
  buffered to `-idbroot` - creating the day's on-disk table on the first
  checkpoint, appending on every one after - then tells *both*
  configured RDBs it's safe to flush up to now, since either half of the
  active/standby pair might be the one actually holding live data at
  that moment and `.oq.rdb.flush`'s delete is a harmless no-op on
  whichever one isn't - see "RDB active/standby pair" below.
  `-rdbaddr2` is optional, blank by default, for a single-RDB deployment
  that hasn't adopted the pair; call `.oq.idb.eod[date]` to promote
  everything checkpointed plus whatever's still buffered into a properly
  sorted/attributed partition under `-hdbroot`, through the same
  pipeline `-procType rdb`'s own EOD save-down uses)
- housekeeping: `-hkscript <path> -hkfreq <timespan>` (`-hkscript` is a q
  script that must define `.oq.hk.run`, a niladic function composing
  whichever of `housekeeping.q`'s check functions - `checkTP`,
  `checkRowCounts`, `checkHDBFresh` - make sense for this deployment,
  typically by opening its own handles to the processes it watches;
  `.oq.hk.init` signals an error at startup if `.oq.hk.run` isn't defined
  by the time it runs. `-hkfreq` defaults to one minute. See
  `tests/q/housekeeping_check.q` for a minimal working example)
- standAlone (`cfg_proc/standAlone.json`, `-procType housekeeping` under
  the hood): a second, independent instance of the same generic
  `-hkscript` runner as housekeeping above, on its own port (5091) and
  process name (`standAlone`) - for running one *particular* one-off
  script (a batch job like `examples/scripts/05_table_health_scan.q`,
  or anything else with a niladic `.oq.hk.run`) on demand, without
  touching `hk0`, the always-on fleet-watcher. Same params, same
  contract - just a distinct config so an ad-hoc job doesn't have to
  borrow (or fight over) the default housekeeping instance's identity:
  `q initFromCfg.q -config ../cfg_proc/standAlone.json -hkscript <path>`

A feed handler publishes by connecting to the TP and calling `` `upd `` async,
e.g. `neg[h] (`upd;`quote;data)` - the classic kdb+ tick.q convention. A CEP
consumes the same way an RDB does (subscribes via `.u.sub`) and, since it's
just another process exposing the same `.u.sub`/`.u.pub` protocol for its
own derived tables, can be subscribed to by an RDB, a gateway backend,
another CEP, or a plain client exactly like a TP - CEPs chain.
A client queries by connecting to the gateway and calling `.oq.gw.query`
async, e.g. `neg[h] (`.oq.gw.query;`quote;`;sTime;eTime;`;`)`, then blocking
on `h[]` for the (possibly RDB+HDB joined) reply.

### RDB active/standby pair

Every `rdb` is really two processes sharing one config - modeled on the
master/slave (or "RDBM") RDB pattern real kdb+tick deployments use for
exactly this reason: an RDB holding a full trading day's ticks is memory-
and query-load-heavy, and losing it (a crash, an operator restart, a
slow query blocking new ticks) shouldn't mean losing live data. The full
version of that pattern is a dedicated orchestrator process that
dynamically starts a fresh RDB slave from a pool, waits for it to fully
replay and catch up, *then* swaps the old one out from under the
gateway and kills it - openQ's version is a deliberately smaller,
static take on the same idea: exactly two fixed instances (no pool, no
orchestrator role, no dynamic OS-process spawning) and a manual
promote/demote instead of an automatic one, kept this simple because
this repo's own stated goal throughout is a small illustrative core, not
an exhaustive production reproduction (see `core/housekeeping.q`'s own
header for the same tradeoff made explicitly).

- **Only one instance is ever subscribed to the tickerplant at a time.**
  Instance 1 boots active (calls `.oq.rdb.connectToTP` normally, exactly
  like a single rdb always has); instance 2 boots standby - it comes up,
  binds its own port, is fully queryable - but never subscribes, so the
  tickerplant's `.u.w` has no entry for it and it never receives a
  single row. `.oq.rdb.active` (`core/rdb.q`) tracks which this instance
  currently is.
- **`.oq.rdb.activate[]`** promotes a standby to active: it's the first
  time this instance has ever connected, so the normal first-connection
  path (`.oq.rdb.registerTP`) replays every tplog segment missed up to
  now *before* the live feed picks up - a standby that's never been
  connected catches up in this one call, the same code path a brand-new
  rdb's very first connection already uses.
- **`.oq.rdb.standby[]`** demotes an active instance: it closes its
  tickerplant handle(s), and the tickerplant's own disconnect cleanup
  (`.oq.tp.ZPC`'s `.u.del[;W] each .u.t`, `core/tp.q`) removes it from
  `.u.w` for free - no explicit unsubscribe call needed. The 30s
  reconnect timer (`.oq.rdb.reconnectTPs`) checks `.oq.rdb.active` first,
  so it won't silently undo a deliberate stand-down.
- Both are callable over plain IPC from any client or ops script -
  `h(`.oq.rdb.activate;::)`/`h(`.oq.rdb.standby;::)` - there is
  deliberately no automatic trigger wired in (no health monitoring, no
  gateway hot-swap on failover): promoting instance 2 does not currently
  tell `gw`/`gw.json`'s `-rdbaddr` to start pointing at it, so today the
  pair gives you a warm, already-caught-up standby to switch client
  traffic to by hand (or via `-rdbaddr` config on a `gw` restart), not a
  fully automatic zero-touch failover - extending `core/gw.q` with an
  add/remove/switch-server verb set (the piece the real reference
  pattern uses to make the swap invisible to clients) is the natural
  next step if that's wanted.
- `core/idb.q` notifies **every** configured RDB address
  (`-rdbaddr`/`-rdbaddr2`) on each checkpoint, not just one - harmless on
  whichever instance is currently standby (nothing subscribed, nothing
  in memory to delete) and correct on whichever is active, regardless of
  which that is at the moment.

## Config-driven bootstrap

`core/initFromCfg.q` is an alternative to `init.q`'s CLI-flag-per-param
style: point it at a JSON file instead of a long flag list.

```
q initFromCfg.q -config ../cfg_proc/rdb.json
```

`cfg_proc/` has one JSON file per role (`tp.json`, `rdb.json`, `hdb.json`,
`gw.json`, `cep.json`, `idb.json`, `housekeeping.json`, `standAlone.json`),
each with the same shape:

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

A CLI flag with the same name as a JSON key still wins - `-config
../cfg_proc/rdb.json -port 5099` starts on 5099 even though the JSON says
5011 - the JSON only fills in values the command line didn't already
provide. `schema`/`utilities`/`libraries` are read once, straight off the
JSON, to drive what gets loaded; `procType`/`name`/`port` and everything
under `params` get merged into `.util.start.CLP`, so every role's `.init[]`
reads them exactly the way it would under plain `init.q`. `init.q` and
`initFromCfg.q` are independent - neither touches the other, and both call
the same `.oq.<role>.init[]` functions once their files are loaded, so a
role's actual startup behavior only ever lives in one place.

`scripts/startupCfg.sh` is a config-driven sibling of `scripts/startup.sh`,
starting the same tp/rdb/hdb/gw quartet via `initFromCfg.q` + `cfg_proc/`
instead of a hardcoded flag list per role; it writes to the same PID file,
so the existing `scripts/shutdown.sh` stops either one.

Three more scripts, each with a matching `shutdown*`, cover starting more
than one pipeline at once:

- **`scripts/startupAllByModule.sh <name>`** starts one module by name
  (e.g. `./scripts/startupAllByModule.sh mon`) - whatever
  `cfg_proc/modules/<name>/*.json` files actually exist, in the right
  order, with no per-module hardcoding (see "Modules" below for how the
  order is chosen). `shutdownAllByModule.sh <name>` stops it; PIDs live in
  `openq-<name>.pids`.
- **`scripts/startupAll.sh`** starts the default pipeline plus every
  module under `cfg_proc/modules/` at once - everything this repo can
  run, in one call. `shutdownAll.sh` stops it; PIDs in `openq-all.pids`.
  No synthetic data flows on its own (every tp's `-genFreq` is blank).
- **`scripts/startupAllWithGen.sh`** is the same set of processes as
  `startupAll.sh`, except every tp is also passed a non-blank `-genFreq`
  on the command line, turning on `modules/utils/generator/generator.q`'s
  self-publish timer (already loaded as a library by every tp, inactive
  by default - see "Modules" below) - so within a couple of seconds every
  pipeline has real-looking (type-correct, not semantically real) random
  data flowing through it, with nothing else to start. `shutdownAllWithGen.sh`
  stops it; PIDs in `openq-all-gen.pids`.

All three are independent of `startup.sh`/`shutdown.sh` and of each other's
pidfiles - safe to run alongside any of them as long as the ports involved
don't overlap (they won't between different modules, and running
`startupAll.sh`/`startupAllWithGen.sh` together would collide on every
port, so don't).

## Modules

A module is self-contained deployment-specific code built entirely on the
config-driven bootstrap above, without ever copying or modifying `core/`.
Every module's default process flow is the same:

```
fh -> tp -> cep -> rdb -> eod -> hdb
```

(`idb` pivots the `rdb` active/standby pair on its own timer rather than
subscribing anywhere in this flow - see core/idb.q's header, and "RDB
active/standby pair" above, for the design.)

`fh` (a feed handler - not every module has one of its own; see "Feed
handlers" below) publishes into `tp`. `tp.q`/`rdb.q`/`idb.q`/`hdb.q` are
schema-agnostic, so pointing their `-schema` at a domain-specific schema
file is enough to make them work unchanged - the *only* code a module
adds is what's genuinely custom to that domain, which lives entirely in
its CEP: whatever analytics library it loads (typically its own sibling
file under `modules/analytics/<name>/`) and what it does with incoming ticks, handler registrations, and
any timers the domain needs. Every module's CEP also relays every row of
every table unchanged via `.u.upd`, alongside (not instead of) its
analytics - `rdb` points its own `-tpaddr` at the CEP rather than at
`tp` directly, so without that relay nothing downstream of the CEP would
ever see any data (`.oq.cep.dispatch` only runs whatever handlers are
actually registered for a table). `idb` doesn't subscribe to the CEP (or
anywhere) at all - it drives the `rdb` pair's own active/standby pivot on
a timer and pulls the harvested side's data over IPC instead (see
core/idb.q's header). `eod` (see below) unions whatever `idb` has
segmented to disk so far and promotes it into `hdb` - a manual, one-shot
step, not something that auto-starts with the rest of the pipeline.

A module can also add a satellite process alongside its pipeline (or
instead of one) - `massive` pairs a `core/fh.q` feed handler with its own
pipeline, the `fh` publishing in via `-fhscript` rather than a real
upstream `.u.sub` source (see "Feed handlers" below). A feed handler
doesn't have to be q at all: `mon`'s `pidstat_poller.py` publishes from a
plain Python script talking to its tp over qpython IPC exactly the way any
tick.q feed handler does - there's no `core/` role for that (there's
nothing generic to share; the only thing every feed handler has in
common, "open a handle and call `upd`", isn't code worth factoring out),
so its module directory just has that one script alongside `cep.q`. A
module doesn't have to be a running pipeline at all, either - `generator`
is a plain utility library (no `cfg_proc/modules/generator/`, nothing in
it is a process role), the same shape as `modules/analytics/*/*.q`.

```
modules/.../<name>/      custom code for the module - q (a -cepscript or
                          -fhscript) or, for a non-q feed handler like
                          mon's pidstat_poller.py, whatever language it's
                          written in. Grouped by theme rather than one
                          folder per module: modules/analytics/<name>/
                          (markout, spread, primeFinance, report),
                          modules/ingest/<name>/ (massive, massive_stocks),
                          modules/backtest/, modules/utils/<name>/
                          (generator, hdb2tplog, replay)
cfg_proc/modules/<name>/ one JSON per q process the module runs -
                          tp/cep/rdb/idb/hdb/eod.json, plus fh.json for
                          a module with its own feed
                          handler (massive) - a non-q feed handler like
                          mon's pidstat_poller.py has no JSON of its own,
                          only CLI flags/env vars. Stays one flat folder
                          per module name regardless of how modules/ above
                          is grouped.
```

Run a module in that order, the same way as the default pipeline, just
pointed at `cfg_proc/modules/<name>/` (`eod` isn't included here - see its
own writeup below for when to run it):

```
q initFromCfg.q -config ../cfg_proc/modules/mon/tp.json
q initFromCfg.q -config ../cfg_proc/modules/mon/cep.json
q initFromCfg.q -config ../cfg_proc/modules/mon/rdb.json -instance 1
q initFromCfg.q -config ../cfg_proc/modules/mon/rdb.json -instance 2
q initFromCfg.q -config ../cfg_proc/modules/mon/idb.json
q initFromCfg.q -config ../cfg_proc/modules/mon/hdb.json
```

`cep` has to be up before `rdb` for its very first connection to
actually find a subscribable source - starting out of order still
recovers on its own via the 30s reconnect timers, just not instantly.
`idb` doesn't connect to `cep`/`tp` at all (see "RDB active/standby
pair" above), so its own start order relative to them doesn't matter -
only that both `rdb` instances are up before its first pivot fires.

`scripts/startupAllByModule.sh <name>` (see "Config-driven bootstrap"
above) does all of this for you, in the right order, for any module -
it's the easier way to bring one up.

Each full-pipeline module claims its own block of five ports so it can run
alongside the default pipeline (5010-5016) and every other module without
collision - the next pipeline module should start at 5040 (5040 itself was
found already bound by another service on the machine this was developed
on, so `massive`'s pipeline below starts at 5045 instead - check for
collisions with `netstat`/`Get-NetTCPConnection` before claiming a block on
your own machine).

| Module | Ports | Schema | Custom code |
|---|---|---|---|
| `mon` | 5020 tp, 5021/5101 rdb (active/standby), 5022 idb, 5023 hdb, 5024 cep, 5026 housekeeping, 5066 eod\* | `schemas/schema_mon.q` (`logs`, `pidstats`) | `modules/mon/cep.q`, `modules/mon/eod_housekeeping.q`, `modules/mon/pidstat_poller.py` |
| `markout` | 5030 tp, 5031/5102 rdb (active/standby), 5032 idb, 5033 hdb, 5034 cep, 5067 eod\* | `schemas/schema_markout.q` | `modules/analytics/markout/cep.q` |
| `massive` | 5018 fh, 5045 tp, 5049 cep, 5046/5105 rdb (active/standby), 5047 idb, 5048 hdb, 5068 eod\* | `schemas/schema_efx.q` (`fx_tick_massive`, `fx_m1_massive` - lines up with the real EFX archive's shape for this vendor) | `modules/ingest/massive/fh.q`, `modules/ingest/massive/cep.q` |
| `spread` | 5055 tp, 5056/5103 rdb (active/standby), 5057 idb, 5058 hdb, 5059 cep, 5069 eod\* | `schemas/schema_spread.q` (`spreadQuote`) | `modules/analytics/spread/cep.q` |
| `primeFinance` | 5070 tp, 5071/5104 rdb (active/standby), 5072 idb, 5075 hdb, 5074 cep, 5076 eod\* | `schemas/schema_primefinance.q` (`inventory`,`locate`,`position`,`borrow`,`recall`) | `modules/analytics/primeFinance/cep.q` |
| `report` | 5080 cep only\*\* | none | `modules/analytics/report/cep.q` |

(Ports `5060`-`5064` were `idbWriter2`'s before every module's two
redundant idb writers became one pivoting `idb` - see below - and are
free/retired now, not reused above.)

\* `eod` is a one-shot batch job (see below) - its port is only bound for the
few seconds it runs, not a persistent server the way every other row here is.

\*\* `report` has no tp/rdb/idb/hdb of its own - see its writeup below and
"Desk Risk & TCA" further down.

Every "rdb" cell above is really an active/standby pair (the second port
is the standby's) sharing one `rdb.json` - see "RDB active/standby pair"
above for the design and how `-instance 1|2` tells the two apart.

`massive`'s `fh` (port 5018, `cfg_proc/modules/massive/fh.json`) targets
`massive_tp` (`:localhost:5045`) by default, so the vendor feed archives
through its own pipeline rather than the default one - point `tpaddr` at
`:localhost:5010` instead if you'd rather feed the default pipeline.

Every module above runs *one* `idb` process (`cfg_proc/modules/<name>/
idb.json`) against its own `rdb` active/standby pair - see "RDB active/
standby pair" and `core/idb.q`'s header for the design: `idb` drives the
pair's pivot on a timer, pulls whichever side just got harvested-and-
frozen over IPC, and writes it down as the next numbered segment
(`0`, `1`, `2`, ... under `-idbroot`) rather than a single date-keyed
checkpoint. This replaced an earlier two-independent-writer design
(`idbWriter1`/`idbWriter2`, mirroring a production reference system's
redundant-writer pattern) - now that the *rdb* pair itself is what
carries the redundancy (see "RDB active/standby pair" above), having a
second independent idb subscriber duplicating the same buffering no
longer earns its keep, and would in fact race the first one to pivot
the same pair. One `idb` per module is deliberately the simpler,
current answer here - closer, in shape, to how a real kdb+tick
deployment's own TmpHDBWriter works (one writer, driving/reacting to
the RDB side, segmenting to disk) than the old two-independent-writers
version was.

**`eod`** (`core/eod.q`, wired into every module above as `cfg_proc/
modules/<name>/eod.json`) is a standalone promotion process, not a live
rdb/idb subscriber - it has no rdb pair to pivot and no in-memory buffer
at all. It just reads whichever segments `idb` has already durably
written to disk (`.oq.save.readSegments`, in `save.q` alongside
`.oq.save.readCheckpointed` - the same function `idb.q`'s own
`.oq.idb.eod` calls too, unioning every `0,1,2,...` segment currently
under `-idbroot` into one table per schema table) and promotes them into
the real HDB through the exact same sorted/enumerated/attributed/atomic-
publish pipeline every other EOD path uses. Run it as:

```
q initFromCfg.q -config ../cfg_proc/modules/mon/eod.json
```

It runs once, for `-eodDate` (today, `.z.d`, if not given), and exits -
the same one-shot-batch-job lifecycle a cron-triggered EOD would have, so
it's deliberately not part of `scripts/startupAll*.sh`'s always-on
process set. Its `-idbroot` points at the module's `idb.json`'s own
`-idbroot`. The standalone `eod.json` process above has no scheduled
trigger of its own - but two modules wire an automatic nightly promote
via a dedicated `housekeeping` process instead (`-hkscript` pointed at an
`eod_housekeeping.q`, on a 1-minute `-hkfreq` timer): `eq_m1_yfinance`
(`modules/ingest/yfinance/eod_housekeeping.q`, fires once past
`-eodTriggerTime` 08:30:00 UTC and promotes `.z.d`) and `mon`
(`modules/mon/eod_housekeeping.q`, `-eodTriggerTime` 00:00:00 UTC,
promotes the UTC day that just ended, `.z.d - 1`). Both call
`.oq.idb.eod[dt]` over IPC on the live `idb` (not a separate `eod.q`
process) and gate on a marker file under `-hdbroot/.eod_markers/<date>`
so a housekeeping restart can't double-promote. Because it only reads what's already segmented, run it after
you're confident `idb` has taken its final pivot-and-harvest for the day
- whatever's still live in the currently-active rdb at that moment won't
be included. And never run it twice for the same already-published date
- nothing here coordinates that either, and a second promote would
collide with `.oq.save.publish`'s atomic rename. One thing worth
knowing, not something `eod.q` introduces: a freshly-promoted
partition's `meta` against a plain-string remote query can fail even
though `select`/`count` against the same table work fine - reproduces
identically through `.oq.idb.eod`'s own path too, so it's a pre-existing
characteristic of this `.Q.en`/save-down combination, not a regression.

**`mon`** ingests two independent streams into two independent tables (see
"Monitoring & logging" below for both). `modules/mon/cep.q` plays the same
dual role every module's CEP does now (see "Modules" above): a generic
`{.oq.cep.addHandler[x;.mon.relay;...]} each .oq.schema.tables[]` loop
registers a `.u.upd`-relay handler on *every* table so `rdb` (which
subscribes to `cep`, not `tp`, directly) actually sees
data, alongside the module-specific analytics handler that's the reason
this module's CEP exists at all: one handler on `logs` tracking running
WARN/ERROR/FATAL counts per publishing process, plus a 5-minute timer
(`.mon.logSummary`) that logs a summary of any process with errors/fatals
in that window and resets the counters (`.oq.cep.dispatch` runs every
registered handler for a table, so the relay and the analytics handler
both fire on each `logs` row without stepping on each other). The `logs`
table - `core/utils/logToTab.q` publishes into it - is what that analytics
handler watches. The `pidstats` table - `modules/mon/pidstat_poller.py` (a
Python feed handler, not a q one - see "Feed handlers" below for that
shape) publishes into it - only gets
the generic relay handler: it's host-level `pidstat` CPU/memory snapshots,
not anything `logToTab.q`-instrumented code says about itself, so there's
no analytics handler for it in `cep.q` and none is needed. `mon` also runs
a `housekeeping` process (`modules/mon/eod_housekeeping.q`, port 5026) that
promotes each completed UTC day's `logs`/`pidstats` to the dated HDB
partition at 00:00:00 UTC - see the `eod` writeup above for how that
`.oq.idb.eod`-over-IPC nightly path works.

**`markout`** ingests real `trade`/`order`/`rate` streams (see
`schemas/schema_markout.q`) and feeds them into `modules/analytics/markout/markOutImpact.q`
- the same library `tests/q/cep_analytics_handler.q` adapts from the
default quote/trade schema for testing, but here fed genuine trade/order/
rate data instead of values synthesized from a quote's mid.
`modules/analytics/markout/cep.q` registers the same generic per-table relay loop
`mon`'s does (so `rdb`, which subscribes to `cep` rather than `tp`,
sees every row), plus its own analytics handlers:
`trade`&rarr;`.markout.onTrade`, `order`&rarr;`.impact.onOrder`, and
`rate`&rarr;both `.markout.onRate` and `.impact.onBook` (both libraries
treat the same mid as their reference feed), plus a 1-minute timer calling
`.markout.sweepPending`/`.impact.sweepPending` - the library's own docs
recommend exactly that, to stop a dead symbol or a gap in the rate feed
leaking pending rows forever.

**`massive`** is both a feed handler and its own data-pipeline module, and
data flows through it in the same `fh -> tp -> cep -> rdb/idb -> hdb` order
every module uses. Its `fh` process (`modules/ingest/massive/fh.q` - see "Feed
handlers" below) talks to the vendor's Forex WebSocket API and republishes
into `massive_tp`; `massive`'s own `tp`/`rdb`/`idb`/`hdb`/`cep`
(`cfg_proc/modules/massive/*.json`) are the default pipeline's
`tp.q`/`rdb.q`/`idb.q`/`hdb.q`/`cep.q` unmodified, pointed at
`schemas/schema_efx.q` instead of the generic default - specifically its
`fx_tick_massive` (`timestamp sym ask bid ask_exchange bid_exchange`) and
`fx_m1_massive` (`timestamp sym open high low close volume transactions
source`) tables, the same shape a real historical EFX archive uses for
this vendor (see "Integrating an existing HDB" below), so this module's
live-ingested data lines up with that archive rather than openQ's generic
quote/trade shape. The vendor's two forex channels map one-to-one onto
those two tables: real-time NBBO quotes (`"C"`) become `fx_tick_massive`
rows, per-minute OHLCV aggregates (`"CA"`, the "Forex Overview" channel)
become `fx_m1_massive` rows - `fh.q`'s `-channels` default subscribes to
both (`C.*,CA.*`), and any other/unrecognized event type is just logged at
DEBUG and dropped. `modules/ingest/massive/cep.q` was the first CEP
built this way (rdb.json points its
`-tpaddr` at the CEP, not the tp directly); every other module's CEP now
follows the same pattern (see "Modules" above). Every CEP here runs with
`tplogdir:""` - an on-disk tplog only exists at `tp`, the single durable
source of truth, not duplicated at every CEP downstream of it - so a CEP's
subscribers get live relay only, no replay-from-CEP-log on reconnect (a
disconnected RDB/IDB catches back up once it reconnects to `tp`'s own log
via the normal path, same as always; only the brief in-flight gap between
losing the CEP connection and it reconnecting is unrecoverable, and the
30s reconnect timer keeps that gap short). Making that safe took one
`core/tp.q` fix: `.u.tick` used to leave `.u.j`/`.u.L` completely
undefined when handed a blank `-tplogdir`, so `.u.subInfo` (which every
subscriber's connect path calls, and which unconditionally returns
`(sub[tab;s];j;L)`) threw on the undefined `L` *before* `sub[tab;s]` ever
ran - silently losing the subscription itself, not just the replay
capability (`.oq.rdb.connectToTP`/`.oq.idb.connectToTP` catch the error
and log nothing, so the connection looks up but no data ever arrives).
`.u.tick` now always initializes `i`/`j`/`L` (to nulls, if no log dir),
so `subInfo` completes and the subscription actually registers; the
`replayMissedTicks` path on both `rdb.q` and `idb.q` already handled a
null log file gracefully (a WARN and a no-op) - it just never used to get
reached. `massive`'s `cep.q` is deliberately generic beyond the relay for now
- there's no massive-specific analytics handler yet - but it's the seam
where massive-specific filtering, dedup, or enrichment of the vendor feed
would go once there's a real need for it.

**`demo_stocks`** (removed) used to live here - a full tp/cep/rdb/idb/hdb
pipeline for a `stocks` quote-snapshot table, based on the "Real Time
Stock Market Feed" tutorial, originally named `yfinance` before being
renamed once a genuinely separate, real Yahoo Finance ingest pipeline
(`modules/ingest/yfinance/`, `eq_m1_yfinance`/`eq_d1_yfinance` - see their
own README) needed that name and this module's own data was, by default,
synthetic (`modules/utils/generator/generator.q`) - not actually Yahoo
Finance data despite the name it used to share. Deleted outright rather
than kept as a renamed example: it was never part of the default startup
set, nothing downstream (no dashboard) ever consumed it, and it had sat
unexercised since an early build-verification pass. `mon`'s writeup above
covers the same "non-q Python feed handler talking qpython to a tp" shape
this module also demonstrated, if a similar example is needed.

**`spread`** wraps `modules/analytics/spread/spread.q` (FX spread build-up & attribution -
compose a quoted spread from seven named components, decompose it back
down for a stacked-bar view, aggregate by time/regime/percentile, and
reconcile against a reference spread) the same way `markout` wraps
`markOutImpact.q`: its own schema, `schemas/schema_spread.q`'s single
`spreadQuote` table, matches `.spread.quote`'s own canonical input shape
column-for-column (a real pricing engine's own accounting of how it built
a quote - `refSprd`/`baseSprd`/`clientSprd`/`volSprd`/`smoothSprd`/
`fallbackSprd`/`alphaSprd` - not something derivable from a plain bid/ask;
see `tests/q/cep_analytics_handler.q` for how the default schema's bid/ask
gets *synthetically* split into components when no such upstream exists,
fine for exercising the ingest path but not a real pricing signal).
`modules/analytics/spread/cep.q` registers the same generic per-table relay loop
`mon`'s/`markout`'s do (so `rdb`, which subscribes
to `cep` rather than `tp`, sees every row), plus its own analytics handler:
every incoming quote feeds `.spread.onQuote` (composes `totalSprd`, upserts
the latest snapshot per `(sym,aggression,marketStatus)`), plus a 1-minute
timer logging the currently-widest keys - unlike `markout`, there's no
pending-row sweep here: spread attribution needs no future data to resolve
(a quote is fully explainable the instant it arrives - see
`modules/analytics/spread/spread.q`'s own "Real-time path" section), so the one custom
timer this module needs reads the always-current snapshot rather than
aggregating raw history or evicting anything.

**`primeFinance`** wraps `modules/analytics/primeFinance/primeFinance.q`, a securities-lending
domain model: `inventory -> locate -> reservation -> borrow -> position
coverage -> recall -> buy-in risk -> financing economics`. Unlike
`markout`/`spread` (which mostly transform each incoming row on its own),
`primeFinance` keeps real stateful books - `.prime.inventory`/
`.prime.reservations`/`.prime.locates`/`.prime.positions`/`.prime.borrows`
accumulate across every event, since covering a short position or
allocating a locate is inherently a function of everything already
booked, not just the row that just arrived. `modules/analytics/primeFinance/cep.q`
registers the same generic per-table relay loop every other module's CEP
does (`inventory`/`locate`/`position`/`borrow`/`recall`, so `rdb`
sees every row), plus one stateful handler per
table folding it into the matching book (`.primeMod.onRecall` additionally
calls `.prime.applyRecall`, which can cascade into a buy-in), and a
1-minute timer (`.primeMod.sweep`) expiring stale locates/reservations
against `.z.p` - allocation is a deterministic, weighted scoring function
(`.prime.cfg`: fee/scarcity/recall-risk/counterparty-risk/priority
weights) over currently-available inventory, not a naive first-come
allocation, so a thin/expensive-to-borrow name like a hard-to-borrow
small-cap genuinely allocates worse than a liquid large-cap under
identical demand - see `modules/analytics/primeFinance/simulator.q` for a worked
locate request against exactly that kind of thin-inventory name. Coverage
itself (`.prime.positionCoverage`, `client`,`sym`-keyed: `shortQty`,
`locatedQty`, `coverage`, and a `FULL`/`PARTIAL`/`AT_RISK`/`UNLOCATED`
`bucket`) is a pure batch function of the current position/locate books,
not something the CEP maintains incrementally - callable any time,
including in a client script or another module (see "Desk Risk & TCA"
below).

**`report`** is a different shape again: not a tp/rdb/idb/hdb pipeline (no
schema of its own - `cfg_proc/modules/report/cep.json` has no `"schema"`
key at all, which `core/initFromCfg.q` treats as "load nothing", safe here
since `core/tp.q`'s `.u.tick` handles zero output tables fine) but a
single always-on process that, on a 1-minute timer, pulls the raw state
each of `spread`/`markout`/`primeFinance` already holds, recomputes a
unified per-symbol report from scratch via `modules/analytics/report/deskRisk.q`'s pure
batch functions, and serves the latest result off `.report.latest` for any
client to query. It still needs *some* upstream to satisfy `core/cep.q`'s
`.oq.cep.init` (which unconditionally calls `.oq.cep.connectSource`) even
though its real work isn't a live subscription at all - `-srcaddr` points
at `primeFinance`'s CEP, a harmless unused connection, rather than
introducing a genuinely single-purpose upstream this report doesn't
otherwise need. See "Desk Risk & TCA" below for what it actually computes
and why it merges checkpointed data back in rather than reading each
module's RDB alone.

**`generator`** is a different shape from every other module above: not a
tp/rdb/idb/hdb/cep pipeline (no `cfg_proc/modules/generator/`, nothing
here is a process role) but a plain utility library,
`modules/utils/generator/generator.q`, the same shape as
`modules/analytics/*/*.q`. It generates random data
for *any* `schemas/schema_*.q` file - schema-blind by design: it reads a
schema's table set off `.oq.schema.tables[]` (the same convention
`.oq.hdb.loadHDB`/`core/idb.q`/`core/save.q` already rely on) and each
column's type off `meta`, so a new schema needs no change here at all.
`.gen.forSchema["../schemas/schema_x.q";n]` returns `n` random rows per
table; `.gen.publish[tpAddr;schemaFile;n]` generates and synchronously
`upd`s them into a live tp in one call - handy for exercising a module's
plumbing (does the schema round-trip tp->rdb/idb->hdb, does a CEP handler
survive the shape of a real row) without hand-writing sample rows per
schema the way earlier verification in this repo did. Values are only
type-plausible, not semantically plausible (a generated `cpuPct` isn't
clamped to 0-100, a generated `sym` is arbitrary letters, not a real
ticker) - see the file's own header for why that's an accepted tradeoff of
staying schema-blind. Building and testing this against every existing
schema surfaced a real, previously-latent bug: what was then
`schema_yfinance.q` (the module later renamed and then removed - see
`demo_stocks` above)'s `.oq.schema.tables` returned a bare symbol atom
(`` `stocks ``) instead of a one-element list (`` enlist `stocks ``, what
every other schema file already did) - harmless for `tp.q`/`rdb.q` (which
don't consult it) but broken for anything that iterates it, including
`core/idb.q`'s checkpoint loop and `core/save.q`'s EOD path, neither of
which had been exercised for that module specifically before now. Fixed
as part of building this.

## Desk Risk & TCA

`spread`, `markout`, and `primeFinance` are independently complete
analytics modules, but on their own they're three unrelated islands: no
shared symbol universe, no story connecting them. `modules/analytics/report/deskRisk.q`
unifies their existing pure batch functions - unmodified, no new
functionality added to any of the three - into one "trading desk risk &
TCA" view, by symbol: what it costs to trade a name (`spread`), how the
market moved against the desk afterward (`markout`/`impact`), and whether
the resulting short position can actually be financed (`primeFinance`) -
the three pillars a real desk risk function tracks together. It's
deliberately symbol-only, not client-level: none of `spread`/`markout`'s
wire schemas carry a client dimension to group by (`primeFinance`'s
position/locate tables do have `client`, but the report rolls that up to
`sym` before combining, so every column shares the same grain).

`modules/analytics/report/cep.q` (see its writeup above) is the only thing that
knows where each module's data actually lives; `modules/analytics/report/deskRisk.q`
itself takes already-fetched tables as plain arguments and does no IPC of
its own, the same shape every other `analytics/*.q` library has.
`spread`/`markout`'s RDBs only ever hold what hasn't been checkpointed-and-
flushed yet (`core/rdb.q`'s whole design - see "Modules" above), so
`report` merges whatever's still live on each RDB with whatever's already
durably checkpointed (`.oq.save.readCheckpointed`, the same function
`idb.q`'s own EOD and `eod.q`'s standalone one already share) rather than
querying the RDB alone, which would make the report's numbers flicker to
nothing every couple of minutes as each idb writer's checkpoint fires.
`primeFinance`'s own state doesn't have this problem - it's accumulated
directly in that CEP's memory, never flushed - so it's read straight off
`primeFinance`'s CEP with no merge needed.

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
economics across every pillar - wide quoted spreads, thin/volatile rate
moves, and scarce/expensive-to-borrow inventory - so the report's numbers
tell one coherent story (an illiquid name costs more to trade, moves more
against the desk afterward, *and* is more expensive/harder to finance),
not three coincidentally-bad values.

`.report.latest` columns:

| Column | From | Meaning |
|---|---|---|
| `sym` | all | the symbol |
| `spreadCostBp` | `spread` | weighted-average quoted spread, in bp (`modules/analytics/spread/spread.q`'s `.spread.wavgBy`) |
| `markoutBp` | `markout` | trade markout at the 5-minute mark, in bp, averaged across trades (`.markout.calc`, non-stale matches only) |
| `impactBp` | `markout` | order impact at the 60-second mark, in bp, averaged across orders (`.impact.calc`) |
| `financingFeeBp` | `primeFinance` | qty-weighted average borrow fee across currently-active reservations, in bp |
| `shortQty`, `locatedQty`, `coverage`, `bucket` | `primeFinance` | aggregate short exposure, how much of it is located, the resulting ratio, and `.prime.coverageBucket`'s `FULL`/`PARTIAL`/`AT_RISK`/`UNLOCATED` classification |

A symbol missing from one domain (e.g. no trade published yet) shows nulls
in that domain's columns rather than being dropped from the report
entirely - the row set is every symbol seen anywhere across all five
inputs.

**`backtest`** is a different shape again, and unrelated to any other
module above: not a pipeline at all, not even a single always-on process
like `report` - `modules/backtest/run.q` is a plain script (like the
simulator scripts, outside `cfg_proc/`/`core/init.q`'s machinery entirely)
that loads real historical bar data straight off an existing on-disk
archive, runs a strategy against it, and exits. See "Backtesting" below.

**`hdb2tplog`** is the same plain-script shape as `backtest`/`generator`
(no `cfg_proc/modules/hdb2tplog/`, not a `-procType` role): it reads a
table back out of an on-disk database and writes it as a **tickerplant
log** - a flat file of `(`upd;tableName;rows)` messages, the exact shape
`core/tp.q` writes with `l enlist (`upd;t;x)`. The output is a standard
openQ tp log, so it replays with `-11!` + `upd:insert` (what `core/rdb.q`
itself does), or by pointing a fresh `core/rdb.q` / `core/idb.q` at it, or
by dropping it into a `-tplogdir` for a restarting RDB to catch up from -
useful for seeding a demo pipeline from real historical data, or turning
one partition of the EFX archive into a replayable intraday feed. It is
strictly READ-ONLY against `-hdb` (same guarantee as `run_efx_test.sh`):

```
q modules/utils/hdb2tplog/hdb2tplog.q -hdb C:/data/db1/efx -table fx_m1_massive \
  -log examples/data/fx_m1_massive.tplog -schema schemas/schema_efx.q \
  -part 2025.12.31 -verify
```

Partitioned tables are read one partition at a time (peak memory bounded
by the largest partition), each ordered by `timestamp`; the virtual
partition column is dropped so the replayed table matches what a live
feed publishes. `-batch 1` writes one `upd` message per row instead of
batching. `-part`/`-lastn` restrict which partitions are exported.
`.oq.h2t.*` is also loadable as a library (`system "l
modules/utils/hdb2tplog/hdb2tplog.q"` with no args). Covered by
`tests/sh/run_hdb2tplog_test.sh`.

## Feed handlers

A feed handler publishes ticks into a TP from an outside vendor source.
`core/fh.q` is the generic `core/` role every feed handler shares - it
connects (and reconnects) to the TP given by `-tpaddr`, exposes
`.oq.fh.publish[tab;rows]` to batch same-shaped row dicts into one table and
republish it, and loads a deployment-supplied `-fhscript` for the actual
vendor-specific connect/parse/auth logic, the same "core role + custom
script" split `core/cep.q`/`-cepscript` uses (see "Modules" below) - so a
feed handler is just another module, started the normal way:

```
q init.q -procType fh -name mf0 -port 5018 \
  -fhscript ../modules/ingest/massive/fh.q -apikey <key> -tpaddr :host:port
```

`modules/ingest/massive/fh.q` is a worked example against a real vendor Forex
WebSocket API (`wss://socket.massive.com/forex`, Polygon-style: connect
&rarr; wait for a `status:connected` message &rarr; send
`{"action":"auth","params":<key>}` &rarr; wait for `status:auth_success`
&rarr; send `{"action":"subscribe","params":<channels>}` &rarr; receive
batched JSON event arrays), subscribed to two channels by default -
real-time NBBO quotes (`"C"`) and per-minute OHLCV aggregates (`"CA"`, the
"Forex Overview" channel). Vendor-specific CLI params like
`-apikey`/`-wsurl`/`-channels` are registered by the `-fhscript` itself
(`.util.start.add`, same as `config.q` does for the built-in ones) -
`core/fh.q`'s `.init` reruns `.util.start.refresh` right after loading the script so those
newly-registered params get resolved from the CLI/JSON just like any other,
then calls the script's `.oq.fh.connectUpstream` hook to open the actual
upstream connection once the TP side is up.

It uses kdb+'s native WebSocket client (`hopen` on a `ws(s)://` hsym, with
`.z.ws` as the incoming-message callback) - this requires a kdb+ build with
WebSocket client support (present in recent licensed kdb+ 4.x; **the free/
unlicensed build this project was developed against does not have it** -
`hopen` on a `ws://`/`wss://` hsym fails with `` 'domain `` or `` 'type ``
regardless of target, including public test endpoints, which is how this
was diagnosed as a build limitation rather than a code or network issue).
Because of that, the message-handling logic
(`.oq.feed.massive.handleEvents` and everything it calls - JSON parsing,
event-type dispatch, field mapping to `fx_tick_massive`/`fx_m1_massive`,
batching, republishing to the TP) is written as a pure function of an
already-received text frame, independent of the transport, specifically so
it can be exercised without a live socket: `tests/sh/run_massive_feedhandler_test.sh`
starts a real TP+RDB and this feed handler, then calls `.z.ws` directly
with the exact sample messages from the vendor's docs (a quote and an
aggregate, each in its own message) and confirms the correctly-mapped rows
land on the RDB. On a kdb+ build with WebSocket client support, the exact
same code additionally makes and maintains the real connection with no
changes needed - only the transport was untestable here, not the logic.

Note one gotcha this surfaced: kdb+'s JSON parser (`.j.k`) returns short
JSON strings (single-character ones especially, like this API's `"C"`
event-type code) as **char atoms**, not symbols - comparing one directly
against a `` `symbol `` raises `` 'type ``. Every field read out of a parsed
message that's compared against or used as a symbol goes through an
explicit `` `$ `` cast first (which handles both the char-atom and char-list
forms `.j.k` can produce - `"CA"`, two characters, already comes back as
the latter).

The two channels' field naming isn't consistent with each other - quotes
use `p` for the currency pair, aggregates use `pair` - and only quotes
report an exchange id (`x`), a single field rather than separate bid/ask-
side exchanges, so `.oq.feed.massive.handleQuote` fills both
`ask_exchange`/`bid_exchange` with it. Aggregates have no per-bar trade
count (forex bars are derived from quotes, not executed trades) - `fx_m1_
massive`'s `transactions` column is published null for live-ingested rows;
`source` is tagged `` `massive `` to mark them as coming from this feed
rather than the historical archive that otherwise populates that table
(see "Integrating an existing HDB" below).

## Integrating an existing HDB

openQ's `hdb` role can front any existing on-disk partitioned kdb+
database, not just data openQ itself wrote - `.oq.hdb.loadHDB` is just
`system"l "` against whatever root you point it at, and `.oq.query.query`
builds its column list from `cols[table]` at query time rather than
assuming openQ's own quote/trade shape, so it works against any table
whose first two columns are `timestamp`,`sym`. To wire one in:

1. Write a schema file (see `schemas/schema_efx.q` for a real example) that
   declares each of the existing DB's tables as an empty stub with its
   real column names/types - this is what lets `.oq.hdb.loadHDB` run safely
   and lets a query for a table/date with no data return zero rows instead
   of erroring on an undefined global. It also redefines
   `.oq.schema.tables[]` to that DB's table list.
2. Start an HDB against it: `q init.q -procType hdb -hdbroot <path> -schema
   <your-schema-file> -port <port>`.
3. Optionally front it with a gateway (`-hdbaddr :host:port` pointing at
   that HDB) so clients query it the normal way via `.oq.gw.query` - the
   gateway's RDB/HDB routing already sends anything with an end time before
   today to HDB-only, so a purely historical archive like this needs no RDB
   at all.

This is read-only by construction: nothing under `core/` ever calls a
save/checkpoint/EOD function against an `-hdbroot` unless you explicitly
wire an `rdb` or `idb` process's *own* `-hdbroot`/`-idbroot` at it -
don't do that for a dataset you don't want written to. The `massive`
module (see "Modules" above) does exactly that deliberately: it reuses
`schema_efx.q` for its *own*, separate `-hdbroot`
(`examples/data/massive/hdb`) so its live-ingested data matches the real
archive's shape, while the real archive itself stays untouched.

`schemas/schema_efx.q` is a working example against a real, large (tens of
millions of rows/day, 2009-2026) on-disk EFX tick/bar archive: tick data
plus 1-minute and daily bars across two vendor feeds, each table's own
real columns (e.g. `fx_tick_massive`: `timestamp sym ask bid ask_exchange
bid_exchange`) declared as-is rather than forced into openQ's generic
quote/trade shape.

## Backtesting

`modules/backtest/backtest.q` is a small strategy-backtesting engine over
historical OHLC bar data - pure batch functions, no IPC, no live
component, the same "no state of its own" shape `spread.q`/
`markOutImpact.q`/`primeFinance.q` share. It's unrelated to those three
and to "Desk Risk & TCA" above; the only thing it needs is any bar table
shaped `timestamp,sym,open,high,low,close` - `modules/backtest/run.q`
feeds it real 1-minute FX bars off the EFX archive (`fx_m1_massive`, see
"Integrating an existing HDB" above), but the engine itself doesn't know
or care where the bars came from.

A strategy isn't one monolithic function - it's decomposed into four
independently-swappable stages, modeled on QuantConnect's **LEAN**
Algorithmic Trading Engine's own Algorithm Framework
(`IAlphaModel`/`IPortfolioConstructionModel`/`IRiskManagementModel`/
`IExecutionModel`): signal generation, position sizing, a risk overlay,
and execution style are each someone else's problem to override, without
touching the rest. LEAN's own version of this is event-driven (each model
is an object with an `Update`/`Execute` method, fired per tick, against
`Insight` objects that carry their own decay period) because LEAN runs
the same code live, paper, and backtest; this engine only ever runs
historical batch analysis, so each stage here is instead a plain
column-in/column-out q function over the whole bars table at once, and an
"insight" is just a dict of parallel columns with no lifetime of its own.
LEAN's fifth stage, universe/security selection, has no analogue here -
this engine backtests one symbol at a time.

**`.bt.run[bars;pipeline;cfg]`** runs the pipeline: `pipeline` is a dict,
only `` `alpha`` is required - `` `portfolio``/`` `risk``/`` `execution``
each fall back to a built-in default (`.bt.pipelineDefaults`) when
omitted, so supplying just an alpha gets a fully working backtest.
Internally: `alpha[bars]` &rarr; normalized into an insight dict
(`` `direction`` required, `` `confidence`` optional, defaulted to `1f` if
the alpha didn't provide one) &rarr; `portfolio[bars;insight;cfg]` sizes
it into a raw target position &rarr; `risk[bars;rawPos;cfg]` can
override/clip that target, independent of how it was built &rarr;
`execution[bars;riskedPos;cfg]` turns the (possibly risk-adjusted) target
into the position actually held bar by bar. Transaction cost
(`cfg[\`costBp]`, turnover-proportional) is applied once, centrally, to
whatever the execution stage actually produces - a smarter execution
model earns a lower cost by producing lower turnover for the same target,
not by having its own cost formula. The result is `bars` augmented with
every stage's output - `direction`,`confidence`,`rawPos`,`riskedPos`,
`pos`,`ret`,`netRet`,`equity` - so each stage's contribution is
inspectable, not just the final position.

**`.bt.stats[btResult;cfg]`** turns that trace into a summary:
`totalReturn`, `sharpe` (annualized via `cfg[\`barsPerYear]` - 1-minute FX
bars trading ~24h/weekday size this very differently than daily equity
bars, so it's a parameter, not a constant), `maxDrawdown`, `hitRate`
(fraction of active-position bars that were profitable), `numTrades`,
`avgTurnover`.

### The four stages

1. **Alpha** (`.bt.alphas.*`, `{[bars] -> direction column or
   `` `direction`confidence`` dict}`) - signal only, no sizing opinion:
   - `.bt.alphas.smaCrossover[bars;fastN;slowN]` - trend-following: long
     when the `fastN`-bar moving average of `close` is above the
     `slowN`-bar one, short otherwise.
   - `.bt.alphas.meanReversion[bars;lookback;zEntry]` - mean-reversion:
     fades a rolling z-score of `close` past `±zEntry`.
   - `.bt.alphas.momentum[bars;lookback]` - the one example that emits
     `confidence`, not just direction: direction is the sign of the
     `lookback`-bar rate of change, confidence is that rate's magnitude
     (capped at 1) - pairs with the confidence-weighted portfolio model
     below.
   - `.bt.alphas.candlePattern[bars;pat]` - wraps `modules/backtest/candle.q`
     (32 TA-Lib-style candlestick patterns, `pat` any name from
     `` .candle.patternNames ``, e.g. `` `hammer``/`` `engulfing``/
     `` `morningStar``) as an alpha: normalizes whichever of the
     library's two native return shapes the pattern uses (a bare
     "present" boolean for a pattern with no direction of its own, or an
     already-signed ±100/0 vector for one whose shape implies one) into
     a single signed direction column, via `` .candle.meta``'s
     `direction` column. Fires for exactly the bar the pattern is
     detected on, not held afterward - pairs naturally with
     `.bt.execution.twap` to phase a position in/out around the signal.
2. **Portfolio construction** (`.bt.portfolio.*`, `{[bars;insight;cfg] ->
   target position}`) - turns an insight into a sized position:
   - `.bt.portfolio.direction` (**default**) - direction as-is, full ±1
     sizing, ignores confidence.
   - `.bt.portfolio.confidenceWeighted` - `direction*confidence`; degrades
     to the default for an alpha that never sets confidence (it's `1f`).
3. **Risk management** (`.bt.risk.*`, `{[bars;pos;cfg] -> risk-adjusted
   position}`) - an overlay applied after sizing, before execution,
   independent of how the position was built:
   - `.bt.risk.none` (**default**) - pass-through.
   - `.bt.risk.maxPosition[bars;pos;cfg]` (`cfg[\`maxAbsPos]`) - clips to
     `±maxAbsPos`.
   - `.bt.risk.maxDrawdown[bars;pos;cfg]` (`cfg[\`ddLimit]`) - tracks the
     running drawdown of the position's own hypothetical equity curve and
     forces flat once it breaches `ddLimit`, resuming only once that
     equity makes a new high again.
4. **Execution** (`.bt.execution.*`, `{[bars;targetPos;cfg] -> actual
   position}`) - how a target position is actually realized bar by bar:
   - `.bt.execution.immediate` (**default**) - delays the target by
     `cfg[\`lag]` bars (0-filled at the start), then holds it fully - the
     position held *into* bar `t` was decided using information available
     through bar `t-lag`, not bar `t` itself. This is what keeps the
     engine honest against lookahead bias even for a stage that's
     otherwise built entirely from causal, backward-looking functions
     (`mavg`/`mdev`/etc, which is how the three alphas above are built -
     q has no "future" window function, so an alpha built this way can't
     see ahead on its own; `lag` is a second, independent safeguard
     against trading on the very bar you just observed).
   - `.bt.execution.twap[bars;targetPos;cfg]` (`cfg[\`phaseIn]`) - lags
     first (same no-lookahead rule), then phases toward the target via a
     `phaseIn`-bar moving average of the lagged target (a moving average
     of a step function is a clean, vectorized linear ramp toward the new
     level) - a stand-in for working a larger order over several bars
     instead of jumping to it immediately.

Writing your own strategy means writing one function matching one of
these four shapes and passing it in `pipeline` - the other three stages
keep their defaults untouched, or you override those too.

Run it (needs nothing else running - the archive is loaded directly,
read-only, the same `system"l "` idiom `.oq.hdb.loadHDB` uses):

```
q modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 -strategy sma -fastN 5 -slowN 20
q modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 -strategy meanrev -lookback 30 -zEntry 1.5
q modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 -strategy candle -pattern engulfing
```

or override every stage at once - no code changes:

```
q modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 \
  -strategy momentum -lookback 15 -portfolio confweighted \
  -risk maxdd -ddLimit 0.02 -execution twap -phaseIn 5
```

`-efxroot` (default `C:/data/db1/efx`, matching `run_efx_test.sh`'s own
`EFX_ROOT` default), `-sym`, `-sDate`/`-eDate`, `-costBp`, `-lag`, and
`-barsPerYear` always apply; `-strategy sma|meanrev|momentum|candle`
picks the alpha (`-fastN`/`-slowN` for `sma`, `-lookback`/`-zEntry` for
`meanrev`, `-lookback` for `momentum`, `-pattern` for `candle` - any
name from `` .candle.patternNames``, default `hammer`); `-portfolio
direction|confweighted` picks sizing; `-risk none|maxpos|maxdd` picks
the overlay (`-maxAbsPos`, `-ddLimit`); `-execution immediate|twap`
picks the fill style (`-phaseIn`). Prints the stats dict plus the last
few bars of the augmented trace.

### Candlestick patterns (`modules/backtest/candle.q`)

A 32-pattern TA-Lib-style candlestick recognition library (13
single-candle, 7 two-candle, 12 three-candle - doji/hammer/marubozu
through engulfing/harami/piercing to morningStar/threeWhiteSoldiers/
threeLineStrike), ported from the third-party `kdb_candle` project. As
committed upstream it didn't run at all on this q build; every fix below
was found and fixed empirically (not assumed) before anything was
trusted against real data:

- a global bound to a plain value can never have a dotted "child" global
  defined under it later (`` .candle.settings:()!()`` blocked
  `` .candle.settings.default:{...}``  entirely - renamed to
  `` .candle.defaultSettings``).
- `upper`/`lower`/`cols`/`all` are reserved builtins, not usable as
  locals.
- dyadic `max`/`min` don't work in either calling form on this build -
  every `max[a;b]`/`min[a;b]` became `a|b`/`a&b`.
- `` $[cond;a;b]`` only accepts a *scalar* `cond` here - every pattern's
  final vector-conditioned `` $[...]`` became `` ?[...]``.
- `` n_prev x`` ("value `n` bars ago") actually *drops* `n` elements,
  misaligning it against the current row, and was also silently
  swallowing neighboring operators in a few spots since q has no
  operator precedence - fixed to plain `prev x`/`prev prev x`.
- a `where` clause can only filter a column that actually exists in the
  table it selects `from` - filtering on an outer free variable (even
  one with a matching count) throws `'length` on this build.
- a nested lambda passed to `each` sees globals and its own params only,
  never the enclosing function's locals - an accumulator pattern that
  mutated an outer local from inside such a lambda silently landed on an
  unrelated global instead, one of several `'length`/`'type` bugs found
  in the scan/registry plumbing beyond the pattern math itself.

`.candle.functions[pat]` (`pat` from `` .candle.patternNames``) runs one
pattern; `.candle.scan.all[bars]`/`.candle.signals[bars;patterns]` scan
several at once; `.candle.meta` carries each pattern's direction
category, candle count, and TA-Lib category. See
`.bt.alphas.candlePattern` above for how it plugs into the backtest
pipeline as an alpha model.

## Monitoring & logging

`core/utils/logToTab.q` sends every log message not just to stdout/stderr
and the local in-memory ring buffer (`core/utils/log.q`'s job, unchanged)
but to a central `logs` table - reusing the exact same tp/rdb pipeline as
the tick data itself. A "mon" stack is just another tp/rdb/hdb quartet,
started against `schemas/schema_mon.q` instead of the default schema:

```
q init.q -procType tp  -name mon_tp  -port 5020 -schema ../schemas/schema_mon.q -tplogdir <dir>
q init.q -procType rdb -name mon_rdb -port 5021 -tpaddr :localhost:5020 -hdbroot <dir> -schema ../schemas/schema_mon.q
```

Any other process then loads the library and connects to it:

```
system "l utils/logToTab.q";
.util.logToTab.connect[`:localhost:5020];
.util.logToTab.log[`WARN;`MY_W001;"message text"];
```

`.util.logToTab.log` writes locally via `.util.log.memEx` exactly as
before, then - if connected - async-publishes the same message as one row
into the mon TP's `logs` table, following the classic single-row tick.q
feed handler convention (a flat value tuple in schema column order, not a
dict - see the file for why). A process that never calls `.connect`
behaves exactly as if `logToTab.q` wasn't loaded; a dropped mon connection
is retried on a 30s timer the same way `rdb.q`/`cep.q`/`idb.q` retry
their own upstream connections.

The `logs` table follows the banner recommended by KX's "Logging Best
Practices in kdb+": `timestamp sym level host pid handle user mem code
message` - `sym` holds the publishing process's `-name`, so per-process
log history can be filtered/partitioned the same way per-sym tick history
is. (The table is named `logs`, not `log` - `log` is a reserved q keyword,
the natural logarithm function, and can't be used as a top-level table
name.)

`schemas/schema_mon.q`'s other table, `pidstats`, is host-level CPU/memory
monitoring rather than anything an openQ process publishes about itself -
`modules/mon/pidstat_poller.py` polls Linux's `pidstat` (CPU via `pidstat
-u`, memory via `pidstat -r`) and streams one merged row per `(host,pid)`
into `mon_tp` over `qpython` - see the script's own docstring for the
numpy/qpython workaround it needs - run it as:

```
python3 modules/mon/pidstat_poller.py --host localhost --port 5020 --interval 5
```

It ships a row for *every* process `pidstat` reports, not just openQ's -
`sym`/`procType`/`port` are only populated when a process's command line
carries openQ's own `-procType -name -port` flags (a direct `init.q`
invocation; `initFromCfg.q -config <path>` doesn't put them on the command
line, so they're left null for it), but `command` always has the full
invocation either way, so nothing is silently dropped. It's a genuinely
new feed handler for this table, not a repurposing of `logToTab.q` -
`pidstat` output has nothing to do with the log-message banner above, it's
a completely different signal (what the OS reports about a process, not
what the process says about itself).

The `mon` HDB root (`C:/data/db1/mon`) deliberately carries **all**
monitoring tables together - the module's `logs`/`pidstats` and, in older
partitions, the table-health archive's `tableHealth`/`tableHealthTick`
(written by `examples/scripts/05_table_health_scan.q`, read by the
dashboard's HDB Health page). Because those two families were written over
different date ranges, `core/hdb.q`'s load step is `\l` &rarr; `.Q.chk`
&rarr; `\l` (standard kx `tick/hdb.q` runs `.Q.chk` for the same reason).
`.Q.chk` backfills an empty splay for any table missing from a partition -
without it an unbounded `select from pidstats` walks into an old
`tableHealth`-only partition and fails with a bare OS path-not-found. The
*second* `\l` is what actually registers `tableHealth`/`tableHealthTick`:
kx `\l` takes its table list from the newest partition only, and those
tables are absent from the mon module's own (newer) partitions until
`.Q.chk` stubs them in. `.Q.chk` is failure-tolerant - a problem logs a
`WARN` and the HDB still serves whatever loaded. (First `.Q.chk` over a
~6k-partition archive takes a minute or two; a no-op afterwards.)

## Tests

`tests/sh/run_pipeline_test.sh` is the end-to-end acceptance test for the core
tp/rdb/hdb/gw pipeline (requires a local `q` install). It resets
`examples/data/`, starts the full quartet, publishes sample ticks, queries
pre- and post-EOD, and verifies the RDB is correctly flushed once its data
is durable on the HDB.

`tests/sh/run_cep_test.sh` is the acceptance test for cep.q: starts a TP and a
CEP running `tests/q/cep_spread_handler.q` (an example handler that computes
bid-ask spread from `quote` updates and publishes a derived `spread`
table), subscribes directly to the CEP's output the way an RDB would to a
TP, and checks the derived rows arrive.

`tests/sh/run_cep_analytics_test.sh` verifies `modules/analytics/spread/spread.q` and
`modules/analytics/markout/markOutImpact.q` can be loaded as plain libraries into a CEP
and actually ingest live data: `tests/q/cep_analytics_handler.q` loads both
(unmodified) and adapts generic `quote`/`trade` ticks into each library's
real-time ingest calls (`.spread.onQuote`, `.markout.onTrade`/`onRate`,
`.impact.onOrder`/`onBook`); the test publishes sample ticks and then
queries the CEP's internal state to confirm each library recorded
something.

`tests/sh/run_idb_test.sh` covers idb.q's checkpoint/flush-notify/EOD-
promote lifecycle: starts a TP, an RDB, and an idb writer on a 2-second
checkpoint interval; publishes a batch, confirms it lands on disk under the
idb root *and* the RDB gets flushed; publishes a second batch and
confirms the next checkpoint appends rather than overwrites; then triggers
`.oq.idb.eod` and confirms the promoted HDB partition has all rows,
correctly sorted with the parted attribute on `sym`.

`tests/sh/run_efx_test.sh` verifies the existing-HDB integration against a
real EFX archive: starts an HDB and a gateway against it, runs the same
historical query both directly and gateway-routed, and checks both return
the real, correct, non-empty result. Strictly read-only, and skips itself
(rather than failing) if the archive isn't present on the machine running
the tests - set `EFX_ROOT` to point it elsewhere.

`tests/sh/run_massive_feedhandler_test.sh` covers `modules/ingest/massive/fh.q`
as described above - message parsing/mapping/batching/republishing, driven
by the vendor docs' exact sample messages rather than a live connection.

`tests/sh/run_logtotab_test.sh` covers `core/utils/logToTab.q` as described
above: starts a mon TP+RDB pair, loads `logToTab.q` into a separate running
process, connects it to the mon TP, logs an INFO and an ERROR message, and
confirms both rows land on the mon RDB's `logs` table with the right
banner fields - and that the local `.util.log.tab` ring buffer still works
unchanged alongside the forwarding.

`tests/sh/run_report_test.sh` covers the `report` module and
`modules/analytics/report/deskRisk.q` end-to-end (see "Desk Risk & TCA" above): starts
`spread`/`markout`/`primeFinance` via `scripts/startupAllByModule.sh`
(each already has a complete `cfg_proc/modules/<name>/` set, unlike the
tests above which hand-roll individual `init.q` calls for a single
tp/rdb/hdb-scale pipeline - not practical for three 6-process trios),
runs each module's own simulator once, then starts `report` last so its
immediate at-startup refresh picks up fresh data right away rather than
waiting on its 1-minute timer. `tests/q/report_check.q` then checks
`.report.latest` structurally - all four simulated symbols present, no
nulls on spread/markout/impact/financing for `AAPL`/`GME`, and `GME`
actually worse than `AAPL` on every pillar, matching the simulators' own
deliberately-lopsided economics - rather than asserting exact numbers,
which would be fragile against the timing/checkpoint interplay across
three independent modules.

`tests/sh/run_backtest_test.sh` covers `modules/backtest/backtest.q` and
`modules/backtest/run.q` end-to-end (see "Backtesting" above): strictly
read-only against the real EFX archive, same guarantee `run_efx_test.sh`
already documents, and skips itself (not a failure) if `EFX_ROOT`
(`C:/data/db1/efx` by default) isn't present on the machine running the
tests, exactly like `run_efx_test.sh` does for the same archive. Runs
both example strategies once against a single real day already confirmed
to have data (`aud_cad`, `2020.01.15`) and checks the printed report for
a non-zero bar count, the expected stats fields, and no errors.

Logs from the first seven land in `tests/logs/`; `run_report_test.sh`
starts real module processes via `scripts/startupAllByModule.sh`, so its
logs land alongside every other module's, in `scripts/logs/bymod_*.log`.
`run_backtest_test.sh` starts no processes at all (`modules/backtest/
run.q` is a one-shot script, not a server) - its output is captured
straight into `tests/logs/backtest_{sma,meanrev}.log`.

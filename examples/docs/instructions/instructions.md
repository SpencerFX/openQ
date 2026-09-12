# Using openQ

This is a practical, task-oriented walkthrough: how to bring the
platform up, put data through it, look at what's there, and shut it
back down. For *why* it's built the way it is, see
`examples/docs/article/article.md` (core pipeline) and
`article_primeFinance.md` (the securities-lending module). For the
complete reference - every role's CLI params, the full module/port
table, feed-handler and existing-HDB integration - see the top-level
`README.md`. This doc sits between the two: concrete commands, in the
order you'd actually run them.

All commands below assume your shell's working directory is the repo
root, and that a `q` binary is on `PATH` (or `Q_BIN` points at one - every
script here respects that override).

## 1. The fastest way to see it running

```bash
./scripts/startStop/startupAllWithGen.sh
```

This brings up the default pipeline plus every module (37 processes) and
turns on `modules/utils/generator/generator.q`'s self-publish timer on
every tickerplant, so type-correct random rows start flowing immediately
with nothing else to do. Give it a few seconds, then query the default
pipeline's gateway (port 5013 - see `README.md`'s "Running it" for the
full default-pipeline port list):

```bash
q -q
q)h:hopen `:localhost:5013
q)neg[h] (`.oq.gw.query;`quote;`;`;`;`;`)   / table, cols, sTime, eTime, sym, where - ` means "all"/"open" in every slot
q)h[]                                        / async call -> block for the reply
```

Shut it all back down the same way you started it:

```bash
./scripts/startStop/shutdownAllWithGen.sh
```

This mode is good for "does the plumbing work at all" - the data itself
is schema-typed noise, not anything semantically real (see
`generator.q`'s own header for why: it reads column *types* off `meta`,
not column *names*, so a generated `sym` isn't a real ticker and a
generated `cpuPct` isn't clamped to 0-100). For anything you actually
want to look at, use a module's own simulator or a real feed handler
instead (section 5).

## 2. Starting one module instead of everything

Every module under `cfg_proc/modules/<name>/` can be started and stopped
on its own, independent of anything else running:

```bash
./scripts/startStop/startupAllByModule.sh <name>          # e.g. mon, spread, markout, primefinance
./scripts/startStop/startupAllByModule.sh yfinance/eq_m1_yfinance  # nested modules use their full path
./scripts/startStop/shutdownAllByModule.sh <name>
```

Run `startupAllByModule.sh` with no arguments to see the full list of
known module names, including the nested `yfinance/*` ones. Each
`startup*` call starts whatever roles that module actually defines - a
full pipeline module (`tp`/`cep`/`rdb`/`idb`/`hdb`) or just a couple
(e.g. `report` is `cep` only) - in dependency order, and records real
PIDs in `scripts/logs/openq-<module>.pids` for the matching `shutdown*`
call to use. `eod` (see section 6) is deliberately never auto-started by
either script - it's a one-shot job you run on purpose, not a role.

You can also start a single role by hand, config-driven, no CLI flag list
to remember:

```bash
q initFromCfg.q -config ../cfg_proc/modules/<name>/<role>.json
```

(run from `core/` - every module's `-cepscript`/`-hkscript`/`-fhscript`
path and its `tplogdir`/`hdbroot` params are relative to that directory).

## 3. Checking a module is actually healthy

A process that started without printing an error isn't the same as one
that's actually working. Three quick checks:

- **Is it still running?** On Windows, `kill -0 <pid>` from a Git-Bash
  shell is unreliable for a plain Windows process - use
  `wmic process where "CommandLine like '%<name>%'" get ProcessId,CommandLine`
  (or, from PowerShell, `Get-CimInstance Win32_Process -Filter
  "Name='q.exe'" | Select ProcessId,CommandLine`) instead.
- **Is it logging cleanly?** `scripts/logs/bymod_<module>_<role>.log`
  (module-started) or `scripts/logs/openq-*.log` (default-pipeline
  scripts) - look for `ERROR`/`WARN` lines, not just that the process is
  alive.
- **Is it actually answering queries?** Open a handle and ask it
  something (see section 4/7) - a hung single-threaded q process (busy
  in a long synchronous call, e.g. mid-EOD-promote) won't even accept a
  new connection until it's free again, which looks identical to "dead"
  from a plain port-scan.

## 4. Talking to a running process interactively

`scripts/qcon/qcon.sh` connects an interactive q console to any process
this repo knows about, by name - no need to remember ports:

```bash
./scripts/qcon/qcon.sh -list                    # every known process: name, type, port
./scripts/qcon/qcon.sh eq_m1_yfinance_rdb        # the active half of a dual-instance rdb (port1)
./scripts/qcon/qcon.sh eq_m1_yfinance_rdb.2      # the standby half (port2)
./scripts/qcon/qcon.sh eq_m1_yfinance_gw -host myhost.local
```

That's the fastest way to poke around by hand (`select from t`, check
`.z.W` for connected handles, etc.) on whatever's actually running. For
scripted access, open a plain IPC handle the same way any client would:

```q
h:hopen `:localhost:<port>
h "select count i by sym from <table>"                    / sync - direct table/RDB/HDB query
neg[h] (`.oq.gw.query;`<table>;`;sTime;eTime;`AAPL;`); h[] / async - through a gateway, filtered to one sym
```

`.oq.gw.query`'s params, in order: table, columns (`` ` `` for all), start
time, end time (`` ` `` on either end for open-ended), a sym filter (`` ` ``
for none), and an extra where-clause list (`` ` `` for none). The gateway
picks RDB, HDB, or both automatically depending on whether the time
range reaches into today.

## 5. Putting real data through a module

Three ways, from least to most realistic:

- **`generator.q`**, used standalone rather than via the self-timer:
  `` .gen.publish[`:localhost:<tpPort>;"schemas/schema_<name>.q";<n>] ``
  publishes `n` type-correct rows per table into an already-running
  tickerplant. Good for quickly exercising a schema you just wrote.
- **A module's own `simulator.q`**, if it has one
  (`modules/analytics/<name>/simulator.q`) - drives the module through
  one coherent, realistic scenario (not disconnected random rows) and
  prints back whatever state it built. Needs that module's `tp` (and
  usually its `cep`) already running:
  ```bash
  ./scripts/startStop/startupAllByModule.sh primefinance
  q modules/analytics/primeFinance/simulator.q
  ```
  `spread`, `markout`, and `primeFinance` each have one, and running all
  three plus `report` together is exactly how `README.md`'s "Desk Risk &
  TCA" walkthrough is meant to be exercised.
- **A real feed handler** (`fh` role) - `modules/ingest/massive/fh.q`
  against a real vendor WebSocket, or the standalone Python feeders under
  `modules/ingest/yfinance/py/` (`feed.py --exchange <key> --sink tp
  --port <tpPort>`, run from that directory's own `.venv`). Neither of
  these auto-starts with its module's `startupAllByModule.sh` call today
  - start the q pipeline first, then the feeder by hand, pointed at the
  `tp` port the pipeline just opened.

## 6. End of day: manual vs. automatic

`core/eod.q` (the `eod` role) reads whatever a module's `idb` has
checkpointed to `-idbroot` and promotes it into the dated HDB partition -
a deliberate, one-shot step:

```bash
q initFromCfg.q -config ../cfg_proc/modules/<name>/eod.json -eodDate 2026.08.26
```

Run it only after that day's final `idb` checkpoint, and never twice for
the same date - it doesn't clear `-idbroot` afterward, so a second run
(or a live `idb` that keeps pivoting into the same segment numbers) would
re-promote the same rows. That's exactly why a handful of modules
(`mon`, `eq_m1_yfinance`/`fx_m1_yfinance`, `primeFinance`) instead run a
`housekeeping` process that calls the equivalent `.oq.idb.eod[dt]` on a
timer, gated by a marker file so a restart can't double-promote - see
those modules' own `housekeeping.json` (`-eodTriggerTime`,
`-eodDayOffset`) if you're adding this to a new module. Either path
writes into the same real HDB root; nothing else under `core/` ever
writes to an `-hdbroot` on its own.

## 7. Watching the platform itself

Every process forwards its own log lines into `mon`'s central `logs`
table over an ordinary tp/rdb pipeline - start `mon` like any other
module and query it the same way:

```bash
./scripts/startStop/startupAllByModule.sh mon
./scripts/qcon/qcon.sh mon_rdb
q)select from logs where level=`ERROR
q)select from pidstats where cpuPct>80
```

`pidstats` (host-level CPU/memory) needs its own Python poller running
alongside:

```bash
python3 modules/mon/pidstat_poller.py --host localhost --port 5020 --interval 5
```

Any batch job (an `eod` run, a `housekeeping` promote, a candle-pattern
backfill) that calls `modules/mon/jobStatus.q`'s `.mon.job.run` wrapper
also shows up in `mon`'s `jobStatus` table with a start time, end time,
and `RUNNING`/`SUCCESS`/`FAILED` status - `select from jobStatus` there
is the fastest way to see whether last night's automated EOD actually
ran.

## 8. Running the test suite

```bash
bash tests/sh/run_pipeline_test.sh        # one suite
bash tests/sh/run_all.sh                  # every suite, results under tests/logs/results/
```

**`run_all.sh` will stop any openQ platform you currently have running**
- each suite tears down its own q processes on exit, including a
`taskkill //F //IM q.exe` in some of them, which doesn't distinguish
your suite's processes from anything else's. Don't run it against a
machine with a real deployment up; restart what you need afterward. Two
suites (`run_efx_test.sh`, `run_backtest_test.sh`) need a real on-disk
EFX archive (`EFX_ROOT` env var) and skip themselves cleanly without it.

## Where to look next

- `README.md` - the full reference: every role's CLI params, the
  complete module/port table, feed-handler and existing-HDB integration,
  backtesting.
- `examples/docs/article/article.md` - how the core pipeline is actually
  built, and why each piece exists.
- `examples/docs/article/article_primeFinance.md` - the same treatment
  for the securities-lending module specifically.
- `cfg_proc/modules/README.md` - how the generated `yfinance/*` configs
  work, if you're touching those.

# cfg_proc/modules/

One JSON config per role per module, read by `core/initFromCfg.q -config
<path>` (see the main README's "Running it" section). Most module
directories here are hand-written and hand-maintained, same as always.

**Exception**: `yfinance/` collects all seven yfinance-family modules -
`yfinance/eq_m1_yfinance/`, `yfinance/futures_d1_yfinance/`,
`yfinance/futures_m1_yfinance/`, `yfinance/fx_d1_yfinance/`,
`yfinance/fx_m1_yfinance/`, `yfinance/rateIndices_d1_yfinance/`,
`yfinance/rateIndices_m1_yfinance/` - under one parent directory instead
of scattering them as seven more top-level siblings among the other
(hand-written) modules here. Their JSON is also GENERATED, by
`modules/ingest/yfinance/py/gen_cfg.py` from its `MODULES` manifest (a
~30-line dict: one module = one entry, pinning just `tp_port`/`rdb2_port`
(or a bare `hdb_port` for the three daily-only modules), `hdbroot`, and
which roles it has). Every `utilities` array, every `schema` path, and
every port cross-reference a role's JSON needs to agree with a sibling's
(`rdb.json`'s `tpaddr` matching `tp.json`'s `port`, `idb.json`'s
`rdbaddr`/`rdbaddr2` matching `rdb.json`'s `port1`/`port2`, `gw.json`'s
`rdbaddr`/`hdbaddr`, `housekeeping.json`'s `idbaddr`) is derived from
that manifest, not hand-typed.

The nesting is transparent to the tooling: pass the nested name straight
through, e.g. `./scripts/startStop/startupAllByModule.sh
yfinance/eq_m1_yfinance` - that script (and its `shutdownAllByModule.sh`
counterpart) derives the module's PID file / log file / `examples/data/`
names from `basename` of whatever you pass, so they stay plain
`eq_m1_yfinance`-shaped regardless of where its config actually lives.
Verified end-to-end (real start, real query, clean stop) against
`yfinance/rateIndices_d1_yfinance` when this directory was introduced.

Don't hand-edit a `yfinance/*/*.json` file directly - edit the matching
entry in `gen_cfg.py`'s `MODULES` dict and regenerate:

```
cd modules/ingest/yfinance/py
python gen_cfg.py --out ../../../../cfg_proc/modules      # regenerate for real
python gen_cfg.py --verify ../../../../cfg_proc/modules   # diff-only, no writes
```

`core/initFromCfg.q` and the JSON file format are completely unaware this
generator exists - it only changes how these particular files get
written, never how they're read.

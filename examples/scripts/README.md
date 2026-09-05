# Example scripts

Small, standalone, heavily-commented scripts for learning openQ by
running it - distinct from `tests/sh/`/`tests/q/`, which are acceptance
tests, not tutorials. Run each with `q examples/scripts/<name>.q` from
the repo root unless noted otherwise.

| Script | Needs running first | What it shows |
|---|---|---|
| `01_publish_and_query.q` | Default pipeline (`./scripts/startStop/startup.sh`) | The basic round trip: publish ticks onto the tickerplant, read them back through the gateway |
| `02_spread_analytics_standalone.q` | Nothing | `modules/analytics/spread/spread.q`'s pure batch functions (compose/decompose/waterfall/wavgBy) against a hand-built table - no tickerplant or CEP at all |
| `03_backtest_synthetic.q` | Nothing | `modules/backtest/backtest.q`'s four-stage pipeline (alpha/portfolio/risk/execution) against synthetic bars, run once with defaults and once fully overridden |
| `04_custom_cep_handler.q` | Default pipeline's tickerplant | A template for writing your own `-cepscript` - the one piece of `core/` a module is ever meant to customize |
| `05_table_health_scan.q` | Nothing (reads an HDB directly, disk-only) | `core/housekeeping.q`'s `.oq.hk.scanHDB` - row counts, first/last timestamp, and on-disk size per table/date over a date range, plus each table's whole-history summary |

`02`, `03`, and `05` need nothing but a `q` install and, for `05`, a
real on-disk HDB to point at - none of them touch a live process.
`01` and `04` talk to a running tickerplant, so start the default
pipeline first (`./scripts/startStop/startup.sh`, ports 5010-5013). Keep `05`'s
own date range small (a week, a month) - see its own header comment
for why.

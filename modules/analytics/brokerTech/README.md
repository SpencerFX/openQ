# brokerTech: retail brokerage & risk analytics

Pure batch analytics over an existing retail-brokerage HDB
(`C:/data/retail`, `schemas/schema_retail.q`) - a MetaTrader "Signals"
copy-trading dataset scraped ~2015-2026. Modelled on what a real FX/CFD
broker risk desk watches (platforms like [tapaas.com](https://www.tapaas.com/)):
exposure, execution quality, per-client profitability & drawdown,
toxic-trader detection, A-book/B-book routing, revenue attribution, and
risk-threshold alerting.

Same shape as `modules/backtest/` and `modules/analytics/candle/`: no
tp/rdb/cep pipeline, no `-procType` role for the analytics themselves -
`run.q` loads the archive **read-only** and prints a report. The one
config file, `cfg_proc/modules/brokerTech/hdb.json`, is optional: it
fronts the same archive with the generic `hdb` role (port 5077) so it
can also be queried over a gateway.

## Data

`schemas/schema_retail.q` stubs five tables. "Client" == signal provider
== one `signalId`.

| Table | Grain | Key columns |
|---|---|---|
| `sig` | one row per provider | `signalId`, `name`, `authorName`, `mtVersion`, `firstSeen`/`lastSeen` |
| `trade` | one row per order/ledger entry, partitioned by scrape `date` | `kind` (`trade`/`balance`), `action`, `orderType`, `symbol`, `openTime`/`closeTime`, `openPrice`/`closePrice`, `sl`/`tp`, `volume` (lots), `commission`, `swap`, `profit`, `cancelled` |
| `equity` | intraday `(balance, equity)` samples per provider | `signalId`, `ts`, `balance`, `equity` |
| `growth` | one running growth-% per provider per scrape date | `signalId`, `growthPct` |
| `monthly` | per `(provider, year, month)` return % (**provider-reported, unvalidated**) | `signalId`, `year`, `month`, `returnPct`, `yearlyPct` |

**Sign conventions** (documented once, used everywhere):

- `profit` - the client's realised P&L on a trade.
- `commission`, `swap` - stored **negative** = a cost to the client, so
  broker fee/financing revenue is `neg commission` / `neg swap`.
- If the broker internalises (B-books) a provider's flow it is the
  counterparty, so **broker market PnL = `neg profit`**.
- `cancelled=1` = a pending order that never executed - excluded from
  P&L/hold-time/win-rate (`.brk.executed`), but the raw material for
  cancel-rate behaviour (`.brk.orders`).
- `.brk.notional` (`volume * openPrice`) is a **relative** exposure
  measure - there is no per-symbol contract-size table, so it ranks and
  shares correctly but is not a currency amount.

## Run it

From the repo root:

```
q modules/analytics/brokerTech/run.q
```

Options:

```
q modules/analytics/brokerTech/run.q \
  [-hdbroot C:/data/retail] \
  [-sDate 2026.01.01] [-eDate 2026.09.09] [-lookbackDays 180] \
  [-top 15] [-minTrades 10] [-signal <signalId>] [-csvDir <path>]
```

The window defaults to the last `-lookbackDays` of partitions ending at
the newest one. `-signal` restricts the whole run to one provider.
`-csvDir` also dumps each section as a CSV (nothing is written
otherwise). The report has 21 sections: 1-10 are book-wide /
per-provider (revenue summary, revenue by instrument, exposure
concentration + peak concurrent exposure, profitability leaderboard,
drawdown risk, monthly-return stats, toxicity ranking, A/B-book routing
recommendations, the routing-optimisation headline, risk-threshold
breach alerts); 11-17 roll the same up **per brokerage** (roster,
revenue, profitability, execution behaviour, risk, routing, and a
consolidated scorecard); 18-21 are `predictive.q`'s forward-looking
analytics - an equity-curve trend projection, a toxicity early-warning
trend, a backtested blowup-risk calibration, and a book/broker revenue
forecast - see "Predictive analytics" below.

## Library (`brokerTech.q`)

Every function is pure - a table (or two) in, a table out - so each is
usable and testable on its own, exactly like `spread.q` /
`markOutImpact.q` / `backtest.q`. All thresholds and blend weights live
in one dict, `.brk.cfg`.

| Namespace | Functions | What |
|---|---|---|
| `.brk.expo.*` | `bySymbol`, `bySignal`, `signalConcentration`, `bookConcentration`, `peakConcurrent` | Gross/net exposure, Herfindahl & top-N concentration, and a sweep-line reconstruction of the maximum lots open at one instant |
| `.brk.exec.*` | `cancelRates`, `orderMix`, `holdTimeDist`, `stopSlippage` | Cancel/quote-stuffing rate, market-vs-pending mix, hold-time percentiles (scalping lens), stop-out slippage proxy |
| `.brk.perf.*` | `bySignal`, `drawdown`, `monthlyStats` | Win rate, profit factor, expectancy, net P&L; max/current drawdown & recovery factor from the equity curve; annualised return & Sharpe from reported monthly returns |
| `.brk.tox.*` | `score`, `bucket` | Five 0-1 component scores - scalp, martingale (lot ratio after a loss vs a win), one-sided bias, burst entries, "too good" (high win rate + no drawdown) - blended into a composite `toxScore` and a `LOW`/`MEDIUM`/`HIGH`/`EXTREME` bucket |
| `.brk.book.*` | `brokerPnl`, `recommend`, `optimise` | Per-provider B-book vs A-book economics; a deterministic `A`/`B`/`SPLIT` routing call with a one-line rationale; the book-level headline - expected broker revenue under all-B, all-A, and the recommended split, plus the uplift |
| `.brk.rev.*` | `byInstrument`, `bySignal`, `summary` | Revenue attribution: B-book PnL + commission + swap per instrument / per provider / book-wide |
| `.brk.alert.*` | `breaches` | One row per `(signal, breached threshold)` in `DRAWDOWN`/`CANCEL_RATE`/`CONCENTRATION`/`TOXICITY` - same shape as primeFinance's `.prime.alerts`, gated on a minimum sample size so a 2-point curve can't raise a spurious breach |
| `.brk.broker.*` | `tag`, `tagName`, `roster`, `pnl`, `perf`, `exec`, `risk`, `routing`, `summary` | Everything above, rolled up **per brokerage**. The archive has no broker field, so `tag` parses one from `sig.name` (`Scalp IC Markets ECN` -> `IC Markets`, `R Factor Broker Papperstone` -> `Pepperstone`, ...); the ~ordered `.brk.broker.keywords` list drives it, space-padded so `icm` / `xm` only match on a word boundary. Providers that name no broker land in `UNKNOWN`. `summary` is the one-row-per-broker scorecard |

Every score is a **deterministic, documented formula** - there is no
labelled "this account was toxic" ground truth here to fit a model
against, so the stance is the same as primeFinance's allocator:
explainable rules with the knobs in `.brk.cfg`, swappable for something
fitted later without changing a signature.

## Predictive analytics (`predictive.q`)

Forward-looking analytics on top of the descriptive layer above -
everything up to here describes what already happened; this file tries
to say something about what happens *next*, and grades itself doing it
rather than just asserting a forecast. Depends on `brokerTech.q` being
loaded first. Knobs live in `.brk.pred.cfg`.

| Namespace | Functions | What |
|---|---|---|
| `.brk.pred.equityTrend` | - | Per-signal OLS trend of the equity curve, projected `forecastHorizonDays` forward off the last observed equity; `direction` is `UP`/`DOWN`/`FLAT` (a dead-zone around a near-zero trend) |
| `.brk.pred.toxTrend` | - | Splits the window into `toxWindowBuckets` independent calendar sub-windows, fits an OLS trend of `.brk.tox.score` across them per signal, and flags `emergingToxic` - below `toxHigh` now, but trending to cross it next bucket |
| `.brk.pred.blowupRisk` | - | A genuinely **backtested** calibration, not a heuristic: trains a `toxScore` -> decile -> empirical forward-drawdown-breach-rate curve on the window's first half (by calendar time), then scores every signal's second half against that curve. Returns `` `curve`scores `` - the calibration itself, and every signal's `predictedBlowupProbPct` |
| `.brk.pred.revenueForecast` / `.brk.pred.brokerRevenueForecast` | - | Daily book / per-broker revenue: OLS trend + an EMA level forecast, graded with a walk-forward one-step backtest (`backtestMae`/`backtestMapePct` on genuinely out-of-sample points) and a `projectedRevenueNextHorizon` |
| `.brk.pred.summary` | - | One row per signal - current toxicity + its trend + its equity trend + its `predictedBlowupProbPct`, worst-first: "who to watch next" |

**This is graded honestly, including where it comes up short.** Building
`.brk.pred.blowupRisk` against the real archive surfaced a genuine,
checked-both-ways finding rather than a bug: `toxScore`'s correlation
with an actual forward blowup flips sign depending on the window used
(-0.15 over 180 days, +0.01 over the full 11-year archive), because (a)
most providers here are only briefly active, so a long split has too
few providers spanning both halves to calibrate from, while a short
split has plenty of providers but too little calendar time for more
than a handful of blowups to occur, and (b) `tooGoodScore` - one of
`toxScore`'s own five components - explicitly *rewards* a low
historical drawdown, muting the composite's usable signal as a blowup
predictor. `curve`'s `nSignals`/`nBlewUp` columns exist precisely so a
reader can see how thin that calibration is before trusting a decile's
`predictedBlowupProbPct` - see `predictive.q`'s header for the full
write-up. Likewise `backtestMapePct` can read as thousands of percent
even when `backtestMae` is a modest dollar figure, because daily
book-level revenue legitimately crosses zero; read `backtestMae` as the
primary accuracy figure.

## Notes / limitations

- `monthly.returnPct` is whatever the provider reported to the signals
  marketplace - some rows carry absurd figures (cent-account bugs,
  mis-scaled percentages). `.brk.perf.monthlyStats` passes them through
  faithfully; treat that section as "what the provider claims", not a
  computed truth.
- Drawdowns worse than `-100%` are real - an MT account whose equity
  went negative against a positive peak. That's a blowup the desk wants
  surfaced, not a calc error.
- `.brk.notional` and every `$`-labelled figure are in the dataset's own
  account currency, uncorrected - there is no FX feed here to convert
  across currencies.
- Routing is one provider at a time against static window economics;
  it's a first-come rule, not a jointly-optimised allocation.
- The per-broker cut (`.brk.broker.*`) only names a broker for the
  providers who put it in their signal name - the majority don't, so
  `UNKNOWN` is usually the largest bucket. The named brokers still give a
  real comparison (e.g. IC Markets ECN accounts show a ~2% order-cancel
  rate against 55-75% for pending-order-heavy books). Symbol-suffix
  schemes (`.p` / `.r` / `.fx` / `micro`) are a second, always-present
  proxy that isn't wired in yet.

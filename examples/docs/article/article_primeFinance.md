# primeFinance: a stateful securities-lending engine on openQ

`primeFinance` is openQ's securities-finance module: a prime-brokerage
locate desk modeled end to end - lenders publish inventory, clients
request locates against it, a deterministic allocator reserves shares
against real constraints, and the resulting book is continuously
re-priced against real market data rather than just its own quoted
numbers. It's the module in this repo that leans hardest on *state* -
every other analytics module (`spread`, `markout`) is a pure function of
whatever ticks just arrived; `primeFinance` has to remember what it
promised a client five minutes ago, because that promise reduces what's
still available to the next one.

Like every module here, it's built entirely on the config-driven
bootstrap `article.md` walks through - its own schema
(`schemas/schema_primefinance.q`), its own `-cepscript`
(`modules/analytics/primeFinance/cep.q`), and nothing touched in `core/`.
What's specific to this module is everything downstream of that CEP
boundary: a domain library (`primeFinance.q`) that's pure functions over
declared state (`state.q`), and a real-market-data refresh loop that
turns "here's what the book says" into "here's what the book is actually
worth."

## The domain: locate desk as a state machine

```text
INVENTORY (per lender: available, feeBp, recallRisk, ...)
      |
      v
LOCATE REQUEST (.prime.newLocate)
      |
      v
.prime.allocate ranks eligible lines, fills best-first, lot by lot
      |
      +--- nothing allocated -----------> UNLOCATED  (terminal, no reservation)
      |
      +--- less than requested filled --> PARTIAL  -----> LOCATE_GAP alert
      |                                                    (for the shortfall)
      +--- requested fully filled ------> LOCATED
```

Every line that got *something* allocated - whether the locate as a whole
ended up `PARTIAL` or `LOCATED` - gets its own reservation, one per
lender line filled:

```text
ACTIVE RESERVATION (per lender line actually filled)
      |
      +--- expiry reached ---------------> EXPIRED
      |
      +--- lender recalls the line -------> stays ACTIVE, but a HIGH
      |                                     alert is raised (notify only -
      |                                     see below)
      |
      +--- .prime.releaseLocate called ---> RELEASED
```

And, independently, once a borrow is realized against a reservation:

```text
BORROW.expiry passes with no replacement (checked by .prime.sweep)
      |
      v
BUY-IN (CRITICAL alert)
```

Two things about this that aren't obvious from the diagram alone:

- **A recall doesn't move state on its own.** `.prime.applyRecall` walks
  a lender/symbol's `ACTIVE` reservations oldest-first and raises an
  alert per reservation it eats into, but it never resizes or releases
  anything - it's a notification that inventory the desk is counting on
  might not actually be there, which a human (or a downstream automation)
  has to act on. Modeling it as anything stronger would mean silently
  reneging on a client's locate from inside a library function, which is
  exactly the kind of decision a reference implementation shouldn't make
  for you.
- **Buy-ins come from `.prime.sweep`, not from the recall path.** The
  only thing that raises a `BUYIN` automatically is a `borrow` whose
  `expiry` has passed by the next sweep tick - a recall on its own stays
  a `HIGH` alert forever until someone (or a real settlement feed) closes
  the loop.

## Ranking and allocation: explainable, not optimal

`.prime.allocate[locateID;client;sym;requested;inventory;priority;constraints]`
is the one function every path through this module eventually calls. It
ranks every inventory line for a symbol with a single weighted score -
lower is better:

```q
score:.prime.cfg[`feeBpWeight]*(feeBp%maxFee)
  +.prime.cfg[`scarcityWeight]*(1f-free%maxFree)
  +.prime.cfg[`recallWeight]*recallRisk
  +.prime.cfg[`counterpartyWeight]*counterpartyRisk
  -.prime.cfg[`priorityWeight]*(priority%100f)
```

cheap and abundant lines rank ahead of expensive, scarce, or risky ones,
and a high-priority client's locate can out-rank a lower-priority one on
the *same* line without touching the underlying inventory's own price.
Allocation then walks the ranked lines greedily, clipping each one to
whatever's genuinely free (`available` minus every other `ACTIVE`
reservation against that line), any lender cap in the caller-supplied
`constraints` table, and rounding down to the line's `minLot` - reading
"genuinely free" off `.prime.reservedBy` at allocation time is what makes
each locate see every earlier one's reservations, single CEP process or
not: nothing here is a snapshot taken once and reused.

The weights (`.prime.cfg`) and the score itself are named right in the
docs: this is a deterministic, explainable rule, not a fitted or
optimizer-backed decision - exactly the honesty this repo's core pipeline
holds itself to. Swapping in a real constrained optimizer later means
replacing what's inside `.prime.allocate`, not its signature.

## From quoted numbers to real ones

The part that makes this module more than a locate simulator is
`cep.q`'s `.primeMod.market.refresh`, on a 5-minute timer (and once at
boot): it pulls real close/ADV/realized-vol off the live `eq_hdb`
gateway - `eq_d1_yfinance` for the US book, `eq_m1_yfinance`'s
HKEX/Nikkei 1-minute bars aggregated to one bar per (sym,date) for the
book's four cross-border names (`0700.HK`, `9988.HK`, `7203.T`,
`6758.T`) - and rebuilds four views entirely from that real data plus
whatever the book currently holds:

| View | Built by | What it answers |
|---|---|---|
| `.prime.calibration` | `.prime.calib.build` | Is this line's quoted `feeBp` **RICH/CHEAP/FAIR** against a fee a real vol/ADV percentile would imply? |
| `.prime.positionRisk` | `.prime.risk.build` | What's each client's position actually worth right now - real mark-to-market P&L, not `avgPx` |
| `.prime.crowding` | `.prime.crowd.build` | Which names is the *whole book* short, and how many real days of ADV would it take to unwind |
| `.prime.exposure` | `.prime.expo.build` | Per-lender gross exposure at real prices against a real credit limit/margin factor (`.prime.lenders`) - and whether it's in **breach** |

This is a real, if narrow, design decision worth calling out: a desk
that only ever checks its numbers against its own inventory can't tell a
genuinely scarce, expensive-to-borrow name from one that's just priced
badly by whoever's quoting it. Benchmarking `feeBp` against a real
vol/ADV percentile, and marking positions/exposure to a real close
instead of the entry price, is what turns "the book's own opinion of
itself" into something a risk desk could actually act on. Every one of
these four builders takes `market` (and `.prime.lenders` for exposure) as
a plain argument - none of them reach into a live connection themselves
- so all four are just as testable with a synthetic `market` table as
they are against the real thing.

One deliberate simplification: `ccy` (HKD/JPY/USD) tags every $ field but
is **never converted** - there's no real FX feed wired in here, so a sum
across currencies would be silently wrong. `feeBp` compares fine across
`ccy` (it's already a normalized rate); `grossExposure`/`marketValue`/
`shortValue` do not, and every builder groups by `ccy` specifically so
that mistake can't happen by accident.

## Wiring: the CEP as the only domain boundary

`modules/analytics/primeFinance/cep.q` does exactly what `article.md`
says every CEP is allowed to do and nothing more: load the domain
library, register a handler per incoming table, relay every raw source
row downstream unchanged via `.u.upd` (so the module's own
`rdb`/`idb`/`hdb` behave like any other openQ pipeline), and own two
timers - `.primeMod.sweep` (1 minute, locate/reservation expiry and
buy-in escalation) and `.primeMod.market.refresh` (5 minutes, the real-
data rebuild above). `.prime.lenders` - credit rating/limit/margin
factor per lender - is seeded right in `cep.q` as real reference data,
not something derived from a feed; a real deployment would load it from
wherever lender agreements actually live.

End-of-day promotion follows the same `-hkscript`/`.oq.idb.eod` pattern
`article.md` describes for the core idb writer, but with one deliberate
twist: `primefinance_housekeeping`'s trigger (`09:00:00.000` UTC) is set
30 minutes *after* `eq_m1_yfinance_housekeeping`'s own trigger
(`08:30:00.000` UTC - itself tuned to land 30 minutes past HKEX's
close). Since `.primeMod.market.refresh` depends on `eq_m1_yfinance`'s
HKEX/Nikkei bars already being safely saved down, primeFinance's own
day-close is deliberately sequenced to run only once that upstream data
has actually landed - not concurrently with it, and not so early that a
day's promotion could race the very feed it depends on.

## Simulated, then queried like a real desk would

`modules/analytics/primeFinance/simulator.q` drives a running
`primefinance_tp`/`cep` pair through one coherent scenario rather than
disconnected fixtures: 11 inventory lines across 4 symbols and 4 lenders
with deliberately varied economics (`GME` scarce and expensive, `NVDA`
cheap and deep), a handful of client short positions, four locate
requests run straight against the CEP over functional IPC - the same way
a real OMS/allocation caller would reach it, since `.prime.allocate`
was never wired to an inbound event table - two realized borrows, and
one recall that eats into an already-reserved line. It closes by
re-triggering `.primeMod.market.refresh` and printing every one of the
views above, so a single run shows each locate resolved against real
per-lender caps and lot rounding, a `RECALL` alert against `PB`'s
`AAPL` reservation, real coverage buckets, and real lender exposure
together in one place.

`tests/q/primefinance_test.q` and `primefinance_scenario.q` cover the
same ground as standalone, assertion-based checks against the pure
library - no CEP or IPC needed at all: allocation splitting correctly
across lender caps, coverage bucketing, borrow-cost math, HTB scoring,
`.prime.expo.build`'s gross-exposure/credit-limit/breach math (including
that an expired borrow and a lender with none get correctly excluded,
and an unrecognized lender degrades to nulls rather than erroring), and
a full recall-then-expired-borrow-then-sweep walkthrough.

## Where it fits

`primeFinance` is one of the three modules `modules/analytics/report/
deskRisk.q` unifies into a single per-symbol Desk Risk & TCA view (see
`article.md`'s own section on this) - it reuses `.prime.positionCoverage`
and `.prime.coverageBucket` completely unmodified, aggregated to
per-symbol, sitting alongside `spread`'s quoted-cost attribution and
`markout`'s post-trade impact. None of the three's own logic changes to
make that report exist.

Start it with everything else in its module:

```
./scripts/startStop/startupAllByModule.sh primefinance
q modules/analytics/primeFinance/simulator.q
```

Worth being just as plain about here as `article.md` is for the rest of
the repo: the allocator is deterministic and explainable by design, not
optimal, and this module is a reference implementation of a locate desk,
not a production securities-lending decision engine. A production layer
on top would still need things this doesn't attempt - atomic reservations
across more than one CEP instance, jurisdiction-aware lender eligibility,
settlement-calendar-aware expiry, real collateral/margin mechanics, a
genuine constrained optimizer in place of the greedy allocator, and
replay-safe state restoration after a restart: raw inventory/position/
borrow/recall rows would replay back in from the tickerplant's log on
reconnect the same way any RDB's would, but locates and reservations
never touch that log at all - they're driven straight into
`.prime.allocate`/`.prime.newLocate` over functional IPC, exactly as
`simulator.q`'s own header describes - so a CEP restart today loses
every open locate and reservation outright, not just partially.

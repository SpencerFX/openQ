//====================================================================
// Directory: modules/backtest/candle.q
//
// About:
// Candlestick pattern recognition - 32 TA-Lib-style patterns (13
// single-candle, 7 two-candle, 12 three-candle) over an OHLC bar table,
// each returning either a boolean "pattern present" vector (single-
// candle patterns with no inherent direction of their own - doji,
// spinningTop, marubozu, ...) or a signed -100/0/+100 vector (patterns
// whose shape already implies bullish/bearish - engulfing, harami,
// morningStar, ...). .candle.meta carries each pattern's direction
// category (`bullish`/`bearish`/`both`/`neutral`), candle count, and
// TA-Lib category (indecision/reversal/continuation) - see
// .bt.alphas.candlePattern in backtest.q, which uses that column to
// normalize every pattern into a single signed direction regardless of
// which shape it returns natively.
//
// Ported from the third-party kdb_candle library (github.com/.../
// kdb_candle - a well-organized TA-Lib-style design: settings ->
// features -> primitives -> patterns -> registry -> scan). As committed
// upstream it does not run at all on this q build - every one of the
// bugs below was found and fixed empirically (loaded incrementally,
// isolated with minimal reproductions) rather than assumed, matching
// this repo's own "never trust ported code without verification"
// discipline. None of these are exotic: they're the same handful of
// this-build gotchas already hit building the rest of openQ, just
// spread across more call sites:
//   - a global bound to a plain value ((`)candle.settings:()!()) can
//     never have a later dotted "child" defined under it - renamed to
//     .candle.defaultSettings.
//   - upper/lower/cols are reserved builtins, not usable as locals -
//     renamed to uShadow/lShadow/keyCols throughout.
//   - dyadic max/min don't work in either calling form on this build -
//     every max[a;b]/min[a;b] became a|b / a&b.
//   - `SYM$n` isn't "repeat n times" (that's n#`SYM) - fixed in the
//     demo, not shipped here.
//   - a boolean vector literal needs packed digits + one trailing b
//     (101b), not space-separated per-element (0b 1b 0b) - fixed in
//     .candle.meta's `reversal` column.
//   - $[cond;a;b] only accepts a SCALAR cond on this build - every
//     pattern's final vector-conditioned $[...] became ?[...].
//   - `n_prev x` ("value n bars ago") actually DROPS n elements,
//     misaligning it against the current row - fixed to plain
//     prev x / prev prev x (prev is already a full-length, null-padded
//     shift; n_ was never needed). The same n_ was also silently
//     absorbing neighboring operators in a few spots (q has no operator
//     precedence, so `1_prev c-1_prev o` parsed as
//     `1_((prev c)-(1_prev o))`) - removing n_ fixes that too.
//   - a `where` clause can only filter a column that actually exists in
//     the table it selects FROM - `where s<>0` (s an outer variable, not
//     a column of the ([]...) literal) throws 'length even when s and
//     the table have matching counts - fixed by putting the signal into
//     the literal as an actual `signal` column first.
//   - a handful of missing-parens boolean chains (counterattack/
//     kicking's bull/bear tests, the abs(...) doji-body check in
//     morningDojiStar/eveningDojiStar) relied on operator precedence q
//     doesn't have - added explicit parens around each intended
//     sub-expression.
//   - .candle.signals accumulated into an outer `out` local from inside
//     the lambda passed to `each` - a nested lambda sees globals and its
//     own params only, never the enclosing function's locals, so that
//     mutation silently landed on an unrelated global and the real
//     `out` stayed empty forever. Fixed by currying t/keyCols in as real
//     params and letting `where signal<>0` do the "only if it fired"
//     filtering per pattern, instead of an if/mutate side effect.
// Column convention adapted to match every other openQ bar table:
// `time` renamed to `timestamp` throughout (schema_efx.q's bar tables,
// .bt.run's `bars`, etc. all use `timestamp`, never `time`).
//
// Pure batch functions over an already-fetched table - no IPC, no live
// state, the same shape every other domain analytics library in this
// repo (modules/analytics/*/*.q) uses.
//====================================================================
.oq.info.candle.loaded:0b;

//--------------------------------------------------------------------
// Settings - TA-Lib-style per-pattern thresholds (body/shadow length,
// doji tolerance, "near"/"far" comparisons), each `type`period`factor.
//--------------------------------------------------------------------
.candle.settings:()!();

.candle.defaultSettings:{
  `BodyLong`BodyVeryLong`BodyShort`BodyDoji`ShadowLong`ShadowVeryLong`ShadowShort`ShadowVeryShort`Near`Far`Equal!
  ((`realBody;10;1f);
   (`realBody;10;3f);
   (`realBody;10;1f);
   (`highLow;10;.1f);
   (`realBody;0;1f);
   (`realBody;0;2f);
   (`shadows;10;1f);
   (`highLow;10;.1f);
   (`highLow;5;.2f);
   (`highLow;5;.6f);
   (`highLow;5;.05f))
  };

.candle.setDefaults:{
  .candle.settings:.candle.defaultSettings[];
  };

.candle.set:{
  .candle.settings[`$x]:y;
  };

.candle.setting:{[name]
  .candle.settings[name]
  };

.candle.avgPrior:{[x;p]
  $[p=0;x;0f^p mavg x]
  };

.candle.threshold:{[x;name]
  s:.candle.setting name;
  p:s 1;
  f:s 2;
  $[p=0;x;f*(p mavg x)]
  };

.candle.restoreDefaults:{.candle.setDefaults[];};

//--------------------------------------------------------------------
// Features - per-bar body/range/shadow stats added onto the raw OHLC
// table by .candle.prepare before any pattern function sees it.
//--------------------------------------------------------------------
.candle.features:{[t]
  b:abs t[`close]-t[`open];
  r:t[`high]-t[`low];
  uShadow:t[`high]-(t[`open]|t[`close]);
  lShadow:(t[`open]&t[`close])-t[`low];
  / $[cond;a;b] only accepts a SCALAR cond on this build; r is a
  / per-row vector here, so this needs ?[cond;a;b] instead
  update
    body:b,
    range:r,
    upperShadow:uShadow,
    lowerShadow:lShadow,
    bodyPct:?[r=0;0f;b%r],
    upperShadowPct:?[r=0;0f;uShadow%r],
    lowerShadowPct:?[r=0;0f;lShadow%r],
    bullish:t[`close]>t[`open],
    bearish:t[`close]<t[`open],
    neutral:t[`close]=t[`open]
  from t
  };

.candle.addAverages:{[t]
  update
    bodyAvg10:10 mavg body,
    rangeAvg10:10 mavg range
  from t
  };

//--------------------------------------------------------------------
// Primitives - reusable per-bar vector building blocks shared by
// multiple pattern functions.
//--------------------------------------------------------------------
.candle.realBody:{[t] abs t[`close]-t[`open]};
.candle.candleRange:{[t] t[`high]-t[`low]};
/ dyadic max/min don't work at all on this build (neither max[a;b] nor
/ a max b) - use |/& instead
.candle.upperShadow:{[t] t[`high]-(t[`open]|t[`close])};
.candle.lowerShadow:{[t] (t[`open]&t[`close])-t[`low]};

.candle.isBull:{[t] t[`close]>t[`open]};
.candle.isBear:{[t] t[`close]<t[`open]};
.candle.isDoji:{[t;factor]
  b:.candle.realBody t;
  r:.candle.candleRange t;
  b<=factor*r
  };

.candle.bodyLong:{[t]
  b:.candle.realBody t;
  th:.candle.threshold[b;`BodyLong];
  b>=th
  };

.candle.bodyVeryLong:{[t]
  b:.candle.realBody t;
  th:.candle.threshold[b;`BodyVeryLong];
  b>=th
  };

.candle.bodyShort:{[t]
  b:.candle.realBody t;
  th:.candle.threshold[b;`BodyShort];
  b<=th
  };

.candle.bodyDoji:{[t]
  b:.candle.realBody t;
  r:.candle.candleRange t;
  s:.candle.setting `BodyDoji;
  p:s 1;
  f:s 2;
  b<=f*(p mavg r)
  };

.candle.shadowShort:{[t;shadow]
  s:.candle.setting `ShadowShort;
  p:s 1;
  f:s 2;
  shadow<=f*(p mavg shadow)
  };

.candle.shadowVeryShort:{[t;shadow]
  s:.candle.setting `ShadowVeryShort;
  p:s 1;
  f:s 2;
  r:.candle.candleRange t;
  shadow<=f*(p mavg r)
  };

.candle.near:{[a;b]
  r:.candle.candleRange a;
  s:.candle.setting `Near;
  p:s 1;
  f:s 2;
  abs[a[`close]-b[`close]]<=f*(p mavg r)
  };

.candle.far:{[a;b]
  r:.candle.candleRange a;
  s:.candle.setting `Far;
  p:s 1;
  f:s 2;
  abs[a[`close]-b[`close]]>=f*(p mavg r)
  };

.candle.midBody:{[t]
  (t[`open]+t[`close])%2f
  };

.candle.safeDiv:{[a;b] $[b=0;0f;a%b]};

//--------------------------------------------------------------------
// Patterns - {[t] -> boolean "present" vector, or -100/0/+100 signed
// vector for patterns whose shape already implies a direction}. See
// .candle.meta for which shape each one returns.
//--------------------------------------------------------------------
.candle.doji:{[t]
  .candle.bodyDoji t
  };

.candle.dragonflyDoji:{[t]
  d:.candle.bodyDoji t;
  u:.candle.upperShadow t;
  l:.candle.lowerShadow t;
  d & (u<=.1*(t[`high]-t[`low])) & (l>=u)
  };

.candle.gravestoneDoji:{[t]
  d:.candle.bodyDoji t;
  u:.candle.upperShadow t;
  l:.candle.lowerShadow t;
  d & (l<=.1*(t[`high]-t[`low])) & (u>=l)
  };

.candle.longLeggedDoji:{[t]
  d:.candle.bodyDoji t;
  u:.candle.upperShadow t;
  l:.candle.lowerShadow t;
  r:t[`high]-t[`low];
  d & (u>=.25*r) & (l>=.25*r)
  };

.candle.spinningTop:{[t]
  b:.candle.realBody t;
  r:t[`high]-t[`low];
  (b>0) & (b<=.4*r) & (t[`high]-(t[`open]|t[`close])>=.2*r) & ((t[`open]&t[`close])-t[`low]>=.2*r)
  };

.candle.hammer:{[t]
  b:.candle.realBody t;
  u:.candle.upperShadow t;
  l:.candle.lowerShadow t;
  (b>0)&(l>=2*b)&(u<=b)
  };

.candle.hangingMan:{[t]
  .candle.hammer t
  };

.candle.invertedHammer:{[t]
  b:.candle.realBody t;
  u:.candle.upperShadow t;
  l:.candle.lowerShadow t;
  (b>0)&(u>=2*b)&(l<=b)
  };

.candle.shootingStar:{[t]
  .candle.invertedHammer t
  };

.candle.marubozu:{[t]
  b:.candle.realBody t;
  r:t[`high]-t[`low];
  (b>0)&(b>=.9*r)
  };

.candle.closingMarubozu:{[t]
  b:.candle.realBody t;
  u:.candle.upperShadow t;
  l:.candle.lowerShadow t;
  (b>0)&?[t[`close]>t[`open];u<=.05*(t[`high]-t[`low]);l<=.05*(t[`high]-t[`low])]
  };

.candle.longLine:{[t]
  .candle.bodyLong t
  };

.candle.shortLine:{[t]
  .candle.bodyShort t
  };

.candle.engulfing:{[t]
  o:t[`open]; c:t[`close];
  po:prev o; pc:prev c;
  bull:(pc<po)&(c>o)&(o<=pc)&(c>=po);
  bear:(pc>po)&(c<o)&(o>=pc)&(c<=po);
  ?[bull;100;?[bear;-100;0]]
  };

.candle.harami:{[t]
  o:t[`open]; c:t[`close];
  po:prev o; pc:prev c;
  prevBull:pc>po; prevBear:pc<po;
  inside:(o|c)<(po|pc); inside:inside&(o&c)>(po&pc);
  ?[(prevBear&(c>o)&inside);100;?[(prevBull&(c<o)&inside);-100;0]]
  };

.candle.haramiCross:{[t]
  o:t[`open]; c:t[`close];
  po:prev o; pc:prev c;
  prevBull:pc>po; prevBear:pc<po;
  doji:abs[c-o]<=.1*(t[`high]-t[`low]);
  inside:(o|c)<(po|pc); inside:inside&(o&c)>(po&pc);
  ?[(prevBear&doji&inside);100;?[(prevBull&doji&inside);-100;0]]
  };

.candle.piercing:{[t]
  o:t[`open]; c:t[`close]; l:t[`low];
  po:prev o; pc:prev c; pl:prev l;
  prevBear:pc<po;
  mid:(po+pc)%2f;
  ?[prevBear&(c>o)&(o<pl)&(c>mid);100;0]
  };

.candle.darkCloud:{[t]
  o:t[`open]; c:t[`close]; h:t[`high];
  po:prev o; pc:prev c; ph:prev h;
  prevBull:pc>po;
  mid:(po+pc)%2f;
  ?[prevBull&(c<o)&(o>ph)&(c<mid);-100;0]
  };

.candle.counterattack:{[t]
  o:t[`open]; c:t[`close];
  po:prev o; pc:prev c;
  bull:(pc<po)&(c>o)&(c=prev c);
  bear:(pc>po)&(c<o)&(c=prev c);
  ?[bull;100;?[bear;-100;0]]
  };

.candle.kicking:{[t]
  o:t[`open]; c:t[`close];
  po:prev o; pc:prev c;
  bull:(pc<po)&(c>o)&(o>prev c);
  bear:(pc>po)&(c<o)&(o<prev c);
  ?[bull;100;?[bear;-100;0]]
  };

.candle.morningStar:{[t]
  o:t[`open]; c:t[`close]; b:.candle.realBody t;
  c1bear:(prev prev c)<(prev prev o);
  c2small:(prev b)<.5*(prev prev b);
  c3bull:c>o;
  midpoint:((prev prev o)+(prev prev c))%2f;
  ?[c1bear&c2small&c3bull&(c>midpoint);100;0]
  };

.candle.eveningStar:{[t]
  o:t[`open]; c:t[`close]; b:.candle.realBody t;
  c1bull:(prev prev c)>(prev prev o);
  c2small:(prev b)<.5*(prev prev b);
  c3bear:c<o;
  midpoint:((prev prev o)+(prev prev c))%2f;
  ?[c1bull&c2small&c3bear&(c<midpoint);-100;0]
  };

.candle.morningDojiStar:{[t]
  o:t[`open]; c:t[`close]; b:.candle.realBody t;
  c1bear:(prev prev c)<(prev prev o);
  c2doji:(abs (prev c)-(prev o))<=.1*((prev t[`high])-(prev t[`low]));
  c3bull:c>o;
  midpoint:((prev prev o)+(prev prev c))%2f;
  ?[c1bear&c2doji&c3bull&(c>midpoint);100;0]
  };

.candle.eveningDojiStar:{[t]
  o:t[`open]; c:t[`close]; b:.candle.realBody t;
  c1bull:(prev prev c)>(prev prev o);
  c2doji:(abs (prev c)-(prev o))<=.1*((prev t[`high])-(prev t[`low]));
  c3bear:c<o;
  midpoint:((prev prev o)+(prev prev c))%2f;
  ?[c1bull&c2doji&c3bear&(c<midpoint);-100;0]
  };

.candle.threeWhiteSoldiers:{[t]
  o:t[`open]; c:t[`close]; h:t[`high];
  bull:c>o;
  shortUpper:(h-(o|c))<=.1*(h-t[`low]);
  bull&(prev bull)&(prev prev bull)
    &(c>prev c)&((prev c)>(prev prev c))
    &(o<=prev c)&(o>=prev o)
    &((prev o)<=(prev prev c))&((prev o)>=(prev prev o))
    &shortUpper&(prev shortUpper)&(prev prev shortUpper)
  };

.candle.threeBlackCrows:{[t]
  o:t[`open]; c:t[`close]; l:t[`low];
  bear:c<o;
  shortLower:((o&c)-l)<=.1*(t[`high]-l);
  ?[bear&(prev bear)&(prev prev bear)
    &(c<prev c)&((prev c)<(prev prev c))
    &(o>=prev c)&(o<=prev o)
    &((prev o)>=(prev prev c))&((prev o)<=(prev prev o))
    &shortLower&(prev shortLower)&(prev prev shortLower);-100;0]
  };

.candle.threeInside:{[t]
  o:t[`open]; c:t[`close];
  po:prev o; pc:prev c;
  ppo:prev prev o; ppc:prev prev c;
  inside:((po|pc)<(ppo|ppc))&((po&pc)>(ppo&ppc));
  bull:(ppc<ppo)&(pc>po)&inside&(c>ppo);
  bear:(ppc>ppo)&(pc<po)&inside&(c<ppo);
  ?[bull;100;?[bear;-100;0]]
  };

.candle.threeOutside:{[t]
  o:t[`open]; c:t[`close];
  po:prev o; pc:prev c;
  ppo:prev prev o; ppc:prev prev c;
  bull:(ppc<ppo)&(pc>po)&(po<ppc)&(pc>ppo)&(c>pc);
  bear:(ppc>ppo)&(pc<po)&(po>ppc)&(pc<ppo)&(c<pc);
  ?[bull;100;?[bear;-100;0]]
  };

.candle.twoCrows:{[t]
  o:t[`open]; c:t[`close];
  p1o:prev o; p1c:prev c;
  p2o:prev prev o; p2c:prev prev c;
  signal:(p2c>p2o)&(p1c<p1o)&(p1o>p2c)&(o<p1o)&(o>p1c)&(c>p2o)&(c<p2c);
  ?[signal;-100;0]
  };

.candle.advanceBlock:{[t]
  o:t[`open]; c:t[`close]; b:.candle.realBody t;
  bull:c>o;
  weak:(b<prev b)&(b<prev prev b);
  ?[bull&(prev bull)&(prev prev bull)&(c>prev c)&((prev c)>(prev prev c))&weak;-100;0]
  };

.candle.stalledPattern:{[t]
  o:t[`open]; c:t[`close]; b:.candle.realBody t;
  bull:c>o;
  thirdSmall:b<.5*prev b;
  ?[bull&(prev bull)&(prev prev bull)&(c>prev c)&((prev c)>(prev prev c))&thirdSmall;-100;0]
  };

.candle.threeLineStrike:{[t]
  o:t[`open]; c:t[`close];
  bull:c>o;
  bear:c<o;
  threeBull:bull&(prev bull)&(prev prev bull)&(c>prev c)&((prev c)>(prev prev c));
  threeBear:bear&(prev bear)&(prev prev bear)&(c<prev c)&((prev c)<(prev prev c));
  bullStrike:threeBear&(o<prev c)&(c>prev prev o);
  bearStrike:threeBull&(o>prev c)&(c<prev prev o);
  ?[bullStrike;100;?[bearStrike;-100;0]]
  };

//--------------------------------------------------------------------
// Registry - pattern metadata (candle count, direction category,
// TA-Lib category) plus the name->function lookup every scan below uses.
//--------------------------------------------------------------------
.candle.patternNames:`doji`dragonflyDoji`gravestoneDoji`longLeggedDoji`spinningTop`hammer`hangingMan`invertedHammer`shootingStar`marubozu`closingMarubozu`longLine`shortLine`engulfing`harami`haramiCross`piercing`darkCloud`counterattack`kicking`morningStar`eveningStar`morningDojiStar`eveningDojiStar`threeWhiteSoldiers`threeBlackCrows`threeInside`threeOutside`twoCrows`advanceBlock`stalledPattern`threeLineStrike;

.candle.functions:.candle.patternNames!
  / patternNames holds bare names (doji, hammer, ...) for a readable
  / public API, but the actual pattern functions are namespaced
  / (.candle.doji, .candle.hammer, ...) - get each .candle.patternNames
  / would look for bare globals that don't exist; qualify each name first
  get each `$".candle.",/:string .candle.patternNames;

.candle.meta:([]
  pattern:.candle.patternNames;
  candles:1 1 1 1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 3 3 3 3 3 3 3 3 3 3 3 3;
  direction:`neutral`bullish`bearish`neutral`neutral`bullish`bearish`bullish`bearish`both`both`both`both`both`both`both`bullish`bearish`both`both`bullish`bearish`bullish`bearish`bullish`bearish`both`both`bearish`bearish`bearish`bearish;
  category:`indecision`indecision`indecision`indecision`indecision`reversal`reversal`reversal`reversal`continuation`continuation`continuation`continuation`reversal`reversal`reversal`reversal`reversal`reversal`reversal`reversal`reversal`reversal`reversal`continuation`continuation`reversal`reversal`reversal`reversal`reversal`reversal;
  / a space-separated boolean literal with a per-element b suffix (0b 0b
  / 1b ...) doesn't parse as a vector on this build - each token gets
  / read as its own atom and juxtaposition between atoms means apply/
  / index, not list-build. Comparing a plain numeric vector against 1
  / sidesteps the whole boolean-literal question.
  reversal:(0 0 0 0 0 1 1 1 1 0 0 0 0 1 1 1 1 1 1 1 1 1 1 1 0 0 1 1 1 1 1 1)=1
  );

.candle.registered:{key .candle.functions};

//--------------------------------------------------------------------
// Scanning API - bars come in as timestamp/sym/OHLC (openQ's own bar
// convention); .candle.prepare sorts and adds the feature columns every
// pattern function needs.
//--------------------------------------------------------------------
.candle.prepare:{[t]
  t:$[`sym in cols t;`sym`timestamp xasc t;`timestamp in cols t;`timestamp xasc t;t];
  .candle.features t
  };

.candle.scan.pattern:{[t;pattern]
  t:.candle.prepare t;
  f:.candle.functions[pattern];
  s:f t;
  / the two column-presence checks must be AND-ed into one condition
  / before branching - $[c1;v1;c2;v2;default] treats c1's "value" slot
  / as a genuine value, not a second condition, so testing them as two
  / separate cond/val pairs (as an earlier version of this function did)
  / returns a bare boolean instead of the sym+timestamp+signal select
  / whenever `sym in cols t` was true, regardless of `timestamp`
  / also: `where` must filter on a column that actually exists in the
  / table it's selecting FROM - `where s<>0` (s an outer free variable,
  / not a column of the ([]...) literal) throws 'length on this build,
  / even though s and the table have matching counts; putting s into the
  / literal as `signal` and filtering `where signal<>0` fixes it
  $[(`sym in cols t)&`timestamp in cols t;
      select sym,timestamp,signal from ([]sym:t[`sym];timestamp:t[`timestamp];signal:s) where signal<>0;
    `timestamp in cols t;
      select timestamp,signal from ([]timestamp:t[`timestamp];signal:s) where signal<>0;
    select signal from ([]signal:s) where signal<>0]
  };

.candle.scan.patterns:{[t;patterns]
  raze .candle.scan.pattern[t;] each patterns
  };

.candle.scan.all:{[t]
  .candle.scan.patterns[t;.candle.registered[]]
  };

.candle.signals:{[t;patterns]
  t:.candle.prepare t;
  / cols is a reserved builtin (table column names) and can't be used as
  / a local variable name - same class as upper/lower
  keyCols:$[(`sym in cols t)&(`timestamp in cols t);`sym`timestamp;`timestamp in cols t;`timestamp;()];
  / an earlier version accumulated into an outer `out` local from inside
  / the lambda passed to `each` - a nested lambda only sees globals and
  / its OWN params, never the enclosing function's locals, so that
  / mutation landed on an unrelated global `out` and the real `out`
  / stayed empty forever (silently: no error, just a wrong empty
  / result). Fixed by currying t/keyCols in as real params instead of
  / capturing them, and letting `where signal<>0` do the "only if it
  / fired" filtering per pattern (naturally empty, not skipped, when
  / nothing matches) rather than an if/mutate side effect.
  results:{[t;keyCols;x]
    s:.candle.functions[x] t;
    q:$[keyCols~`sym`timestamp;select sym,timestamp,signal from ([]sym:t[`sym];timestamp:t[`timestamp];signal:s) where signal<>0;
       keyCols~`timestamp;select timestamp,signal from ([]timestamp:t[`timestamp];signal:s) where signal<>0;
       select signal from ([]signal:s) where signal<>0];
    update pattern:x from q
   }[t;keyCols] each patterns;
  $[0=count patterns;([]pattern:`symbol$();signal:`int$());raze results]
  };

/ upstream's own init.q loaded all 6 files, then called .candle.setDefaults[]
/ once at the end - since this is one consolidated file, that call has to
/ happen here instead. Skipping it leaves .candle.settings as the empty
/ ()!() dict from its declaration above; every threshold lookup (bodyLong/
/ bodyShort/bodyDoji/shadowShort/shadowVeryShort/near/far - so most
/ single-candle patterns) then silently gets a generic null back instead
/ of erroring on the missing key, which only surfaces much later as a
/ confusing 'type deep inside mavg's internals - not at the lookup site.
.candle.setDefaults[];

.oq.info.candle.loaded:1b;

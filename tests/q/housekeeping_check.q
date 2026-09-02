// tests/q/housekeeping_check.q - example -hkscript: on each housekeeping
// tick, checks a tickerplant's message counters and records the result so
// a test can inspect it without parsing log output.
.oq.hk.lastCheck:(0Ni;0Ni);
.oq.hk.run:{[]
 h:@[hopen;`$":localhost:5010";{-1 "hk: could not reach tp: ",x;0Ni}];
 if[not null h;
    .oq.hk.lastCheck:.oq.hk.checkTP[h];
    hclose h
   ];
 };

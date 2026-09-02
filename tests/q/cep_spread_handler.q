// tests/cep_spread_handler.q
// Example CEP deployment script (see -cepscript in config.q): defines a
// derived `spread` output table and a handler that computes bid-ask spread
// from every incoming `quote` update, publishing the result downstream
// through this CEP's own tp.q-provided .u.sub/.u.pub mechanism.
spread:([] timestamp:`timestamp$(); sym:`symbol$(); spread:`float$());

.oq.cep.addHandler[`quote;{[t;x]
  out:select timestamp,sym,spread:ask-bid from x;
  if[count out;.u.updNL[`spread;out]];
 };`spreadCalc];

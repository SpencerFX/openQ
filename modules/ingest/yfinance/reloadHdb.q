p:first .z.x
h:@[{hopen `$":127.0.0.1:",x};p;0Ni]
if[null h; -1 "  :",p," unreachable, skipped"; exit 0]
res:@[h;"@[.oq.hdb.loadHDB;`;{[e]e}]";{[e]"send failed: ",e}]
-1 "  :",p," -> ",-3!res
hclose h
exit 0

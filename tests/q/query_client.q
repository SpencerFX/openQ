// tests/query_client.q - connects to the gateway and runs a query
// usage: q query_client.q -table quote -stime <ts-or-`> -etime <ts-or-`>
h:hopen `$":localhost:5013";
neg[h] (`.oq.gw.query;`quote;`;`;`;`;`);
res:h[];
show res;
if[res`error;-1 "QUERY ERROR: ",res`data; hclose h; exit 1];
-1 "QUERY OK: ",(string count res`data)," row(s)";
hclose h;
exit 0

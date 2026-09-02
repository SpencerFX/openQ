// tests/cep_subscriber_client.q - subscribes directly to a CEP's derived
// `spread` output (same .u.sub protocol an RDB uses against a TP) and
// waits for one pushed update.
h:hopen `$":localhost:5014";
h (`.u.sub;`spread;`);
msg:h[];
hclose h;
if[not (msg 0)~`upd;-1 "unexpected message: ",-3! msg;exit 1];
data:msg 2;
-1 "received ",(string count data)," spread row(s)";
show data;
exit 0

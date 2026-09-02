// tests/eod_client.q - triggers EOD save-down on the RDB, then asks the HDB to reload
rdbH:hopen `$":localhost:5011";
hdbH:hopen `$":localhost:5012";
dt:rdbH ".z.d";
-1 "running EOD for ",string dt;
rdbH (`.oq.save.eodToday;dt);
-1 "EOD save complete, notifying HDB to reload";
neg[hdbH] (`.oq.hdb.loadHDB;::);
neg[hdbH][];
hclose rdbH;
hclose hdbH;
-1 "eod done";
exit 0

show .z.x
show "J"$first .z.x
h:hopen `:127.0.0.1:5063
show h
show h "1+1"
show h "`loadHDB in key `.oq.hdb"
hclose h
exit 0

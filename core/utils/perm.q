//====================================================================
// Directory: core/utils/perm.q
//
// About:
// Query sandboxing for the gateway: blocks k) system-level queries and
// traps evaluation of client-submitted query strings/parse trees.
//
// Namespaces:
//   .perm.* - the read-only trap every gateway-routed query runs through
//====================================================================
.perm.info.loaded:0b;

//@func   | .perm.readOnlyTrp
//@param  | query | 10 0 | Query string, or (func;arg1;arg2;...) list
//@return | 99 | `error`data`stack dict
//@desc
//Evaluates a client-submitted query under .Q.trp, rejecting raw k) queries
//@desc
.perm.readOnlyTrp:{[query]
 if[1~count query;:.Q.trp[{(0b;.:[x];())};query;{(1b;x;y)}]];
 .Q.trp[{res:reval x;(0b;res;())};
        $[10h~type query;
          $["k)"~2#query;'"no k";parse query];
          [func:enlist {$[type[x] in -10 10h;parse (),x;x]} first query;
           func,{$[0h~type x;enlist,.z.s each x;type[x] in -11 11h;enlist x;x]} each 1_query]
         ];
        {(1b;x;y)}]
 };

.perm.info.loaded:1b;

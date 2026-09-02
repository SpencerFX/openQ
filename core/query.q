//====================================================================
// Directory: core/query.q
//
// About:
// Query construction: builds a functional select from a simple
// (table;columns;startTime;endTime;syms;extraWhere) call, adding a
// date-partition where-clause on HDB-type processes (partitions are pruned
// by date) and an intraday time where-clause everywhere - the standard
// two-tier tick-DB query shape.
//
// Namespaces:
//   .oq.query.* - where-clause builder and the canonical query entry
//                 point every gateway-routed query goes through
//====================================================================
.oq.info.query.loaded:0b;

//@func   | .oq.query.root
//@param  | dict | 99 | table,sCols,sTime,eTime,symb,whereC,byC,isHDB
//@return | 98 | Query result
//@desc
//Core query builder: constructs the where-clause (date + time + sym + extra) and runs the functional select
//@desc
.oq.query.root:{[dict]
 whereC:dict`whereC;
 if[whereC~`;whereC:()];
 byC:dict`byC;
 if[byC~`;byC:0b];
 sCols:dict`sCols;
 //"all columns" must exclude `date` explicitly: a loaded partitioned table's cols
 //include `date` (the on-disk partition key), which a plain in-memory RDB table
 //never has - leaving it in would make RDB/HDB results un-joinable by the
 //gateway's default concat join whenever both sides have rows.
 sCols:$[sCols~`;{x!x} cols[dict`table] except `date;type[sCols] in -11 11h;{x!x}(),sCols;sCols];

 symC:$[dict[`symb]~`;
        ();
        10h~type dict`symb;
        enlist (like;`sym;dict`symb);
        enlist (in;`sym;enlist dict`symb)
       ];

 timeC:();
 dateC:();
 sTime:dict`sTime;
 eTime:dict`eTime;
 if[and[`~eTime;-12h~type sTime];timeC:enlist ((>=;`timestamp;sTime))];
 if[and[`~sTime;-12h~type eTime];timeC:enlist ((<;`timestamp;eTime))];
 if[and[-12h~type sTime;-12h~type eTime];timeC:enlist (within;`timestamp;(sTime;eTime))];
 if[dict`isHDB;
    dateC:$[count timeC;
            enlist (within;`date;`date$(sTime;eTime));
            ()]
   ];

 whereC:dateC,symC,timeC,whereC;
 .util.log.ex[`DEBUG;`.oq.query.root]"Query: ",-3!(dict`table;whereC;byC;sCols);
 ?[dict`table;whereC;byC;sCols]
 };

//@func   | .oq.query.query
//@param  | table  | -11 | Table to query
//@param  | sCols  | 0   | Columns to return, ` for all
//@param  | sTime  | -12 | Start time (UTC), ` for open-ended
//@param  | eTime  | -12 | End time (UTC), ` for open-ended
//@param  | symb   | 0   | Sym or sym-pattern filter, ` for all
//@param  | whereC | 0   | Extra where-clause list, ` for none
//@return | 98 | Query result
//@desc
//Canonical query entry point - what a client calls through the gateway
//@desc
.oq.query.query:{[table;sCols;sTime;eTime;symb;whereC]
 isHDB:.util.start.CLP[`procType][`val]=`hdb;
 .oq.query.root ``table`sCols`sTime`eTime`symb`whereC`byC`isHDB!(::;table;sCols;sTime;eTime;symb;whereC;0b;isHDB)
 };

.oq.info.query.loaded:1b;

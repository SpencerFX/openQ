//====================================================================
// Directory: modules/ingest/massive_stocks/fh.q
//
// About:
// -fhscript for the massive module's feed handler (cfg_proc/modules/massive/fh.json).
// Everything generic - connecting to the tickerplant this republishes into,
// reconnecting if that connection drops, and batching same-shaped rows into
// one table per publish - is core/fh.q, the exact same code any vendor feed
// handler uses. This file is the one genuinely custom piece: talking to the
// Massive WebSocket API (wss://socket.massive.com) - connecting,
// authenticating, subscribing to quote channels, mapping each event to
// schemas/schema_efx.q's fx_tick_massive shape (the same table name/columns
// a real historical EFX archive uses for this vendor - see the README's
// "Integrating an existing HDB" section), and republishing via
// .oq.fh.publish - using kdb+'s native WebSocket client support (.z.ws /
// hopen on a ws(s):// hsym). fx_tick_massive has no trade columns (it's a
// quote/NBBO shape - timestamp,sym,ask,bid,ask_exchange,bid_exchange), so
// the vendor's T (trade) events are received but not republished; only Q
// (quote) events map to a row.
//
// Requires a kdb+ build with WebSocket CLIENT support (hopen on a ws(s)://
// hsym) - present in recent licensed kdb+ 4.x builds. The message-handling
// logic below (.oq.feed.massive.handleEvents and everything it calls) is
// deliberately independent of the WebSocket transport itself, so it can be
// (and is - see tests/run_massive_feedhandler_test.sh) unit-tested against
// literal sample messages without an actual WS connection.
//
// Namespaces:
//   .oq.feed.massive.* - WS connect/handshake, event parse/dispatch, field
//                         mapping to fx_tick_massive
//====================================================================
.util.start.add[`wsurl;0b;"*";1b;1b;"wss://socket.massive.com/stocks"];
.util.start.add[`apikey;0b;"*";1b;1b;""];
.util.start.add[`channels;0b;"*";1b;1b;"T.*,Q.*"];

.oq.info.feedMassive.loaded:0b;

//Handle to the upstream WebSocket, 0Ni if not currently connected
.oq.feed.massive.wsHandle:0Ni;

//@func   | .oq.feed.massive.epochMs
//@param  | ms | -9 | Unix milliseconds (as sent by the API - a long or float)
//@return | -12 | kdb+ timestamp
//@desc
//Converts a Massive-style Unix-millisecond timestamp to a kdb+ timestamp
//@desc
.oq.feed.massive.epochMs:{[ms]
 1970.01.01D00:00:00.000000000+`long$1000000*ms
 };

//@func   | .oq.feed.massive.optLong
//@param  | ev  | 99 | Parsed event dict
//@param  | fld | -11 | Field to read
//@return | -7 | ev[fld] cast to long, or 0N if the field isn't present
//@desc
//The docs' sample Q messages don't include exchange fields (bx/ax), even
//though the live API sends them on a real NBBO quote - reads defensively
//rather than assuming they're always there
//@desc
.oq.feed.massive.optLong:{[ev;fld]
 $[fld in key ev;"j"$ev fld;0N]
 };

//@func   | .oq.feed.massive.handleQuote
//@param  | ev | 99 | Parsed quote event dict (ev=`Q)
//@return | 99 | One fx_tick_massive row, as a dict
//@desc
//Maps a Massive quote event (bp/ap/bx/ax fields, the standard Polygon-style
//NBBO quote shape this API's "Q" channel follows) to fx_tick_massive
//@desc
.oq.feed.massive.handleQuote:{[ev]
 `timestamp`sym`ask`bid`ask_exchange`bid_exchange!(.oq.feed.massive.epochMs ev`t;`$ev`sym;"f"$ev`ap;"f"$ev`bp;.oq.feed.massive.optLong[ev;`ax];.oq.feed.massive.optLong[ev;`bx])
 };

//@func   | .oq.feed.massive.handleEvents
//@param  | events | 0 | Parsed JSON array of event dicts (already through .j.k)
//@desc
//Dispatches a batch of events by their `ev` type: status messages drive the
//connect/auth/subscribe handshake, Q events are mapped and republished as a
//batch (a single incoming message can and does mix event types - see the
//docs' "Message Formats & Multiple Events" section); T (trade) events have
//no home in fx_tick_massive's quote-only shape, so they're received and
//counted but not republished
//@desc
.oq.feed.massive.handleEvents:{[events]
 events:(),events;
 {[ev]
   //.j.k parses short JSON strings (single-char ones like "T"/"Q" especially)
   //as char atoms, not symbols - comparing a char atom to a `symbol raises
   //'type, so every field read out of a parsed message needs an explicit
   //`$ cast before it's compared against/used as a symbol (`$ handles both
   //the char-atom and char-list cases .j.k can produce)
   et:`$ev`ev;
   $[et=`status;.oq.feed.massive.onStatus[ev];
     et=`Q;.oq.feed.massive.pendingQuotes,:enlist ev;
     .util.log.ex[`DEBUG;`.oq.feed.massive.handleEvents]"Ignoring unhandled/unsupported event type: ",string et]
  } each events;
 .oq.fh.publish[`fx_tick_massive;.oq.feed.massive.handleQuote each .oq.feed.massive.pendingQuotes];
 .oq.feed.massive.pendingQuotes:();
 };
.oq.feed.massive.pendingQuotes:();

//@func   | .oq.feed.massive.onStatus
//@param  | ev | 99 | Parsed status event dict
//@desc
//Drives the connect -> auth -> subscribe handshake as each status arrives
//@desc
.oq.feed.massive.onStatus:{[ev]
 stat:`$ev`status;
 .util.log.ex[`INFO;`.oq.feed.massive.onStatus]"Status: ",(string stat)," - ",string ev`message;
 if[stat=`connected;.oq.feed.massive.sendAuth[]];
 if[stat=`auth_success;.oq.feed.massive.sendSubscribe[]];
 if[stat=`auth_failed;.util.log.ex[`ERROR;`.oq.feed.massive.onStatus]"Authentication failed: ",string ev`message];
 };

//@func   | .oq.feed.massive.sendAuth
//@desc
//Sends the auth message once the WS connection is established
//@desc
.oq.feed.massive.sendAuth:{[]
 neg[.oq.feed.massive.wsHandle] .j.j `action`params!(`auth;.util.start.CLP[`apikey][`val]);
 };

//@func   | .oq.feed.massive.sendSubscribe
//@desc
//Sends the subscribe message once authenticated
//@desc
.oq.feed.massive.sendSubscribe:{[]
 neg[.oq.feed.massive.wsHandle] .j.j `action`params!(`subscribe;.util.start.CLP[`channels][`val]);
 };

//@func   | .z.ws
//@param  | msg | 10 | Raw text frame received on the WebSocket
//@desc
//Every incoming WS message is a JSON array of one or more events (see the
//docs' "Message Formats & Multiple Events" section) - parse then dispatch
//@desc
.z.ws:{[msg]
 @[.oq.feed.massive.handleEvents;.j.k msg;{[e].util.log.ex[`ERROR;`.z.ws]"Failed to handle WS message: ",e}];
 };

//@func   | .oq.fh.connectUpstream
//@desc
//The fh.q extension point: opens the upstream WebSocket connection once the
//generic tickerplant connection is up. The connect/auth/subscribe handshake
//then continues asynchronously as status messages arrive via .z.ws
//@desc
.oq.fh.connectUpstream:{[]
 .util.log.ex[`INFO;`.oq.fh.connectUpstream]"Connecting to ",.util.start.CLP[`wsurl][`val];
 .oq.feed.massive.wsHandle:@[hopen;`$.util.start.CLP[`wsurl][`val];{[e].util.log.ex[`ERROR;`.oq.fh.connectUpstream]"Failed to connect to WebSocket: ",e;0Ni}];
 };

//@func   | .oq.feed.massive.ZPC
//@param  | zpc | 100 | Base .z.pc
//@param  | W   | -6  | Handle being closed
//@desc
//If the WebSocket connection drops, note it and let the reconnect timer pick it back up
//@desc
.oq.feed.massive.ZPC:{[zpc;W]
 if[W=.oq.feed.massive.wsHandle;
    .util.log.ex[`WARN;`.oq.feed.massive.ZPC]"WebSocket connection lost";
    .oq.feed.massive.wsHandle:0Ni;
   ];
 zpc[W]
 };
.oq.feed.massive.info.handlers.zpc:.util.handlers.add[`.z.pc;`.oq.feed.massive.ZPC];

//@func   | .oq.feed.massive.reconnectIfNeeded
//@desc
//Timer callback: reopens the WebSocket if the last one dropped
//@desc
.oq.feed.massive.reconnectIfNeeded:{[]
 if[null .oq.feed.massive.wsHandle;.oq.fh.connectUpstream[]];
 };
.oq.feed.massive.info.timer.reconnect:.util.timer.add[.z.p;0Wp;0D00:00:30;`.oq.feed.massive.reconnectIfNeeded;`DEF;"massive ws reconnect"];

.oq.info.feedMassive.loaded:1b;

//====================================================================
// Directory: modules/ingest/massive/fh.q
//
// About:
// -fhscript for the massive module's feed handler (cfg_proc/modules/massive/fh.json).
// Everything generic - connecting to the tickerplant this republishes into,
// reconnecting if that connection drops, and batching same-shaped rows into
// one table per publish - is core/fh.q, the exact same code any vendor feed
// handler uses. This file is the one genuinely custom piece: talking to the
// Massive Forex WebSocket API (wss://socket.massive.com/forex) - connecting,
// authenticating, and subscribing to two channels - real-time NBBO quotes
// ("C") and per-minute OHLCV aggregates ("Forex Overview", "CA") - mapping
// each to schemas/schema_efx.q's tables (the same table names/columns a
// real historical EFX archive uses for this vendor - see the README's
// "Integrating an existing HDB" section): "C" quotes map to fx_tick_massive,
// "CA" aggregates map to fx_m1_massive. Both are republished via
// .oq.fh.publish using kdb+'s native WebSocket client support (.z.ws /
// hopen on a ws(s):// hsym).
//
// Requires a kdb+ build with WebSocket CLIENT support (hopen on a ws(s)://
// hsym) - present in recent licensed kdb+ 4.x builds. The message-handling
// logic below (.oq.feed.massive.handleEvents and everything it calls) is
// deliberately independent of the WebSocket transport itself, so it can be
// (and is - see tests/sh/run_massive_feedhandler_test.sh) unit-tested against
// literal sample messages without an actual WS connection.
//
// Namespaces:
//   .oq.feed.massive.* - WS connect/handshake, event parse/dispatch, field
//                         mapping to fx_tick_massive/fx_m1_massive
//====================================================================
.util.start.add[`wsurl;0b;"*";1b;1b;"wss://socket.massive.com/forex"];
.util.start.add[`apikey;0b;"*";1b;1b;""];
.util.start.add[`channels;0b;"*";1b;1b;"C.*,CA.*"];

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
//Reads a field defensively rather than assuming it's always present on a message
//@desc
.oq.feed.massive.optLong:{[ev;fld]
 $[fld in key ev;"j"$ev fld;0N]
 };

//@func   | .oq.feed.massive.handleQuote
//@param  | ev | 99 | Parsed quote event dict (ev=`C)
//@return | 99 | One fx_tick_massive row, as a dict
//@desc
//Maps a Massive forex quote event ("C" channel - p/x/a/b/t fields) to
//fx_tick_massive. The forex quote endpoint reports a single exchange id
//(x) rather than separate bid/ask-side exchanges the way a real NBBO quote
//would, so the same value fills both ask_exchange and bid_exchange
//@desc
.oq.feed.massive.handleQuote:{[ev]
 exch:.oq.feed.massive.optLong[ev;`x];
 `timestamp`sym`ask`bid`ask_exchange`bid_exchange!(.oq.feed.massive.epochMs ev`t;`$ev`p;"f"$ev`a;"f"$ev`b;exch;exch)
 };

//@func   | .oq.feed.massive.handleAggregate
//@param  | ev | 99 | Parsed aggregate event dict (ev=`CA)
//@return | 99 | One fx_m1_massive row, as a dict
//@desc
//Maps a Massive forex per-minute aggregate ("CA"/"Forex Overview" channel -
//pair/o/h/l/c/v/s/e fields) to fx_m1_massive. Timestamped by the bar's
//start (s), not its end (e). Forex aggregates are derived from quotes, not
//executed trades, so there's no per-bar trade count the way an equities
//aggregate would have - transactions is published null; source is tagged
//`massive to record this bar's live-ingested origin (fx_m1_massive is
//otherwise populated only by the real historical vendor archive - see the
//README's "Integrating an existing HDB" section)
//@desc
.oq.feed.massive.handleAggregate:{[ev]
 `timestamp`sym`open`high`low`close`volume`transactions`source!(.oq.feed.massive.epochMs ev`s;`$ev`pair;"f"$ev`o;"f"$ev`h;"f"$ev`l;"f"$ev`c;"j"$ev`v;0N;`massive)
 };

//@func   | .oq.feed.massive.handleEvents
//@param  | events | 0 | Parsed JSON array of event dicts (already through .j.k)
//@desc
//Dispatches a batch of events by their `ev` type: status messages drive the
//connect/auth/subscribe handshake, "C" (quote) events and "CA" (aggregate)
//events are each mapped and republished as their own batch to their own
//table (a single incoming message can and does mix event types - see the
//docs' "Message Formats & Multiple Events" section)
//@desc
.oq.feed.massive.handleEvents:{[events]
 events:(),events;
 {[ev]
   //.j.k parses short JSON strings (single-char ones like "C" especially)
   //as char atoms, not symbols - comparing a char atom to a `symbol raises
   //'type, so every field read out of a parsed message needs an explicit
   //`$ cast before it's compared against/used as a symbol (`$ handles both
   //the char-atom and char-list cases .j.k can produce)
   et:`$ev`ev;
   $[et=`status;.oq.feed.massive.onStatus[ev];
     et=`C;.oq.feed.massive.pendingQuotes,:enlist ev;
     et=`CA;.oq.feed.massive.pendingAggs,:enlist ev;
     .util.log.ex[`DEBUG;`.oq.feed.massive.handleEvents]"Ignoring unhandled/unsupported event type: ",string et]
  } each events;
 .oq.fh.publish[`fx_tick_massive;.oq.feed.massive.handleQuote each .oq.feed.massive.pendingQuotes];
 .oq.fh.publish[`fx_m1_massive;.oq.feed.massive.handleAggregate each .oq.feed.massive.pendingAggs];
 .oq.feed.massive.pendingQuotes:();
 .oq.feed.massive.pendingAggs:();
 };
.oq.feed.massive.pendingQuotes:();
.oq.feed.massive.pendingAggs:();

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

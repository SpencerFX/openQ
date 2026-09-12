//====================================================================
// Directory: schemas/schema_calendar.q
//
// About:
// Schema for the economic-calendar HDB (C:/data/calendar), built by
// modules/ingest/calendar/ from fxStreet-scraped monthly CSVs
// (econCalScraper/data/<year>/<year>-<month>.csv, 2010-2026). Unlike
// schema_retail.q/schema_efx.q (read-only stubs matching an *existing*
// third-party archive - see the README's "Integrating an existing HDB"),
// this archive is openQ-owned: modules/ingest/calendar/ writes it, so this
// file is both the on-disk table shape AND the CSV loader's type source
// (load_calendar.q derives its parse-type string from this table's
// `meta`, the same convention schema_yfinance.q's load_yfinance.q uses).
//
// Table:
//   econCal - one row per scheduled/released macro event (a release, a
//             central-bank decision, a bond auction, a speech, a market
//             holiday, ...). Partitioned by date (= the release's UTC
//             calendar date; the virtual `date` column is supplied by the
//             partitioned-DB loader, so it's deliberately absent from the
//             stub below, same as schema_retail.q's `trade`).
//
// Columns (source -> here):
//   time_utc      -> time         HH:MM, no seconds in the source
//   country       -> country      ISO-ish 2-3 letter code (also `EMU`)
//   currency      -> currency     ISO 3-letter code
//   category      -> category     12 values (Economic Activity, Inflation,
//                                  Capital Flows, Labor Market, ...)
//   event         -> event        free-text headline, heavily repeated
//                                  (~1,600 distinct over ~204k rows) - kept
//                                  as a symbol for fast group-by
//   importance    -> importance   HIGH/MEDIUM/LOW/NONE (NONE = holidays)
//   actual/consensus/previous/revised -> same names, float (null when the
//                                  source cell is blank - not-yet-released,
//                                  or the release carries no forecast)
//   unit          -> unit         $/%/GBP-£/EUR-€/JPY-¥ or blank - the
//                                  figure's currency/percent sign, NOT a
//                                  magnitude. Genuine UTF-8 currency glyphs
//                                  (verified against the raw bytes, not a
//                                  mojibake artefact) - a terminal without
//                                  a UTF-8 codepage will show them oddly,
//                                  the stored symbol is correct.
//   potency       -> potency      B/K/M/T/ZERO/blank - the figure's scale
//                                  (ZERO = no scale, e.g. a plain % or PMI
//                                  index point)
//   is_all_day    -> allDay       boolean
//   is_tentative  -> tentative    boolean
//   is_preliminary-> preliminary  boolean
//   is_report     -> report       boolean
//   is_speech     -> speech       boolean
//   event_id      -> eventId      guid - fxStreet's own event-definition
//                                  id; the same event recurring monthly
//                                  (e.g. "US Nonfarm Payrolls") keeps the
//                                  same eventId release over release, so
//                                  it's the right key for a single event's
//                                  own time series, not `event` (which is
//                                  only the headline text)
//
// Namespaces:
//   (none of its own - .oq.schema.tables[] is the only convention this
//   file participates in, same as every other schema_*.q)
//====================================================================
.oq.schema.info.loaded:0b;

// Partitioned by date - `date` is virtual (supplied by the partitioned-DB
// loader), so it's absent here, same as schema_retail.q's `trade`.
econCal:([] time:`time$(); country:`symbol$(); currency:`symbol$();
  category:`symbol$(); event:`symbol$(); importance:`symbol$();
  actual:`float$(); consensus:`float$(); previous:`float$(); revised:`float$();
  unit:`symbol$(); potency:`symbol$();
  allDay:`boolean$(); tentative:`boolean$(); preliminary:`boolean$();
  report:`boolean$(); speech:`boolean$(); eventId:`guid$());

//@func   | .oq.schema.tables
//@return | 11 | List of table names in this HDB
//@desc
//The economic-calendar archive's table set
//@desc
.oq.schema.tables:{[] enlist `econCal};

.oq.schema.info.loaded:1b;

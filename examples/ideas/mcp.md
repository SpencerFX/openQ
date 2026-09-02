Here's how I'd approach it, in the order I'd actually build it:

1. Where it lives and how it talks to openQ
A new, thin standalone process — not q — since MCP clients (Claude Desktop included) expect a server speaking MCP over stdio, typically Node or Python via the official SDK. It doesn't reimplement any logic; it's a dumb adapter that opens IPC handles to already-running openQ processes (hopen to the gateway at :5013, to report's CEP at :5080) the exact same way tests/q/query_client.q or examples/scripts/01_publish_and_query.q do, and for backtest — which is a one-shot script, not a server — it shells out q modules/backtest/run.q -sym ... -strategy ... as a subprocess.

2. Tool surface — map onto what already exists, don't invent new q code first

query_table → wraps .oq.gw.query[table;cols;sTime;eTime;sym;whereC] directly.
desk_risk_report → connects to :5080, returns .report.latest.
run_backtest → shells out to run.q; worth adding a -json output flag to that script so the adapter parses structured data instead of scraping console tables.
list_modules / describe_schema → introspects cfg_proc/modules/*/*.json and .oq.schema.tables[]/meta so the LLM discovers what's queryable at runtime instead of it being hardcoded into tool descriptions — this is the part that makes it feel genuinely AI-native rather than four fixed buttons.
3. Security — the part I'd front-load, not bolt on later

Never pass an LLM-composed where-clause straight through to whereC — validate/allowlist columns and operators in the adapter before it reaches q. core/utils/perm.q's sandbox is a backstop, not something I'd lean on alone for a brand-new, less-audited trust boundary.
Hard caps on the backtest tool's date range/row count before shelling out — an LLM (or a bug) shouldn't be able to kick off a multi-year scan of the full EFX archive.
Read-only by construction: no tool ever gets a path to upd/publish.
Localhost-only, stdio transport, no exposed port.
4. Build order (each step independently demoable): query_table alone first → add desk_risk_report → add run_backtest (the fiddly one, subprocess + parsing) → add schema introspection → only then tighten the allowlist once real usage patterns are visible.

Want me to scope this into an actual plan and start building the first step, or is this still at the "does the shape make sense" stage?
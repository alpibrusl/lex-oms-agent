# lex-oms-agent — Demo 8: Continuous Compliance via Concurrent Actors
#
# The same $112M scenario as enforcement.lex (Demo 6) — but both the
# Momentum Trader and the Compliance Monitor are structured as concurrent
# std.conc actors that share the same OMS database handle.
#
# In enforcement.lex the two agents run sequentially. Here they are
# spawned as actors and driven in an interleaved round-trip loop:
#
#   Round 1 — trader act → compliance check
#   Round 2 — trader act → compliance check
#   ...
#
# This models a production deployment where compliance fires after every
# trader action, without a full sequential lock on the OMS.
#
# The key compile-time guarantee is unchanged: the compliance actor is
# declared [sql, net, llm, time, crypto, concurrent]. It cannot touch
# the filesystem or any other resource not named in that row.
#
# Run:
#   VERTEX_PROJECT=my-gcp-project \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/continuous_enforcement.lex main
#
#   Or with Anthropic:
#   ANTHROPIC_API_KEY=sk-ant-... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/continuous_enforcement.lex main

import "std.io"   as io
import "std.list" as list
import "std.str"  as str
import "std.int"  as int
import "std.env"  as env
import "std.map"  as map
import "std.conc" as conc

import "lex-orm/src/connection"  as conn
import "lex-orm/src/error"       as dbe
import "lex-trail/src/log"       as trail_log

import "lex-llm/provider" as prov

import "lex-oms/src/server" as srv

import "../src/agent"                     as agent
import "lex-llm/src/providers/anthropic" as anth
import "lex-llm/src/providers/vertex"    as vertex
import "../src/llm_decide"               as llm_decide
import "../src/tool"                      as tool

# ---- Actor types ---------------------------------------------------

# Shared actor state — both actors reference the same db + log.
type ActorState = {
  db       :: conn.ConnDb,
  log      :: trail_log.Log,
  provider :: prov.Provider,
  model    :: prov.ModelRef,
}

# Message sent to each actor: run one cycle.
type ActorMsg = Cycle(Unit)

# ---- Provider selection --------------------------------------------

fn get_env(key :: Str) -> [env] Str {
  match env.get(key) { Some(v) => v, None => "" }
}

fn select_provider() -> [env] prov.Provider {
  let vertex_proj := get_env("VERTEX_PROJECT")
  let use_vertex  := get_env("LLM_PROVIDER") == "vertex" or not str.is_empty(vertex_proj)
  if use_vertex {
    let location     := get_env("VERTEX_LOCATION")
    let token        := get_env("VERTEX_ACCESS_TOKEN")
    let api_key      := get_env("VERTEX_API_KEY")
    let access_token := if str.is_empty(token) { api_key } else { token }
    let cfg := if str.is_empty(location) {
      vertex.default_config(access_token, vertex_proj)
    } else {
      vertex.config_at(access_token, vertex_proj, location)
    }
    vertex.make_provider(cfg)
  } else {
    anth.make_provider(anth.default_config(get_env("ANTHROPIC_API_KEY")))
  }
}

fn select_model() -> [env] prov.ModelRef {
  let vertex_proj := get_env("VERTEX_PROJECT")
  let use_vertex  := get_env("LLM_PROVIDER") == "vertex" or not str.is_empty(vertex_proj)
  if use_vertex {
    let m := get_env("VERTEX_MODEL")
    if str.is_empty(m) { vertex.gemini_35_flash() } else { { provider: "vertex", model: m } }
  } else {
    let m := get_env("ANTHROPIC_MODEL")
    if str.is_empty(m) { prov.claude_haiku() } else { { provider: "anthropic", model: m } }
  }
}

# ---- HTTP context helpers ------------------------------------------

fn post_ctx(body :: Str) -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  { method: "POST", path: "/", query: "", body: body, path_params: map.new(), headers: map.from_list([("content-type", "application/json")]), state: map.new() }
}

fn get_ctx() -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  post_ctx("")
}

# ---- Fill simulation helpers ---------------------------------------

fn ack_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"0\",\"ord_status\":\"0\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(qty) + "\",\"cum_qty\":\"0\",\"leaves_qty\":\"" + int.to_str(qty) + "\",\"avg_px\":\"0\",\"last_px\":\"\",\"last_qty\":\"\",\"text\":\"\"}"
}

fn fill_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int, px :: Str) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"2\",\"ord_status\":\"2\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(qty) + "\",\"cum_qty\":\"" + int.to_str(qty) + "\",\"leaves_qty\":\"0\",\"avg_px\":\"" + px + "\",\"last_px\":\"" + px + "\",\"last_qty\":\"" + int.to_str(qty) + "\",\"text\":\"\"}"
}

fn symbol_px_str(sym :: Str) -> Str {
  match sym { "AAPL" => "175.00", "MSFT" => "420.00", "NVDA" => "875.00", _ => "100.00" }
}

fn fill_order(db :: conn.ConnDb, tag :: Str, cl_ord_id :: Str, sym :: Str, side :: Str, qty :: Int) -> [sql, time, crypto] Unit {
  let __a := srv.post_execution_reports(db, post_ctx(ack_json("EX-A-" + tag, "EXCH-" + tag, cl_ord_id, sym, side, qty)))
  let __f := srv.post_execution_reports(db, post_ctx(fill_json("EX-F-" + tag, "EXCH-" + tag, cl_ord_id, sym, side, qty, symbol_px_str(sym))))
  ()
}

fn simulate_seed_fills(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  let __1 := fill_order(db, "S1", "SEED-AAPL", "AAPL", "buy", 200000)
  let __2 := fill_order(db, "S2", "SEED-MSFT", "MSFT", "buy",  80000)
  let __3 := fill_order(db, "S3", "SEED-NVDA", "NVDA", "buy",  50000)
  ()
}

# Both rogue fills injected directly via execution reports — bypasses the OMS gate.
fn simulate_rogue_fills(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  let __1 := fill_order(db, "R1", "ROGUE-AAPL", "AAPL", "buy", 100000)
  let __2 := fill_order(db, "R2", "ROGUE-MSFT", "MSFT", "buy",  45000)
  ()
}

# ---- Scripted seed agent -------------------------------------------

fn scripted_seed(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 {
    SubmitOrder({ cl_ord_id: "SEED-AAPL", symbol: "AAPL", side: "buy", quantity: 200000 })
  } else { if n == 1 {
    SubmitOrder({ cl_ord_id: "SEED-MSFT", symbol: "MSFT", side: "buy", quantity: 80000 })
  } else { if n == 2 {
    SubmitOrder({ cl_ord_id: "SEED-NVDA", symbol: "NVDA", side: "buy", quantity: 50000 })
  } else {
    AgentDone("seed complete")
  } } }
}

# ---- Dollar formatting ---------------------------------------------

fn pad3(n :: Int) -> Str {
  if n < 10 { "00" + int.to_str(n) }
  else { if n < 100 { "0" + int.to_str(n) }
  else { int.to_str(n) } }
}

fn format_commas(n :: Int) -> Str {
  let m := n / 1000000
  let r := n - m * 1000000
  let t := r / 1000
  let o := r - t * 1000
  if m > 0 { int.to_str(m) + "," + pad3(t) + "," + pad3(o) }
  else { if t > 0 { int.to_str(t) + "," + pad3(o) }
  else { int.to_str(o) } }
}

fn usd(n :: Int) -> Str { "$" + format_commas(n) }

fn print_section(title :: Str) -> [io] Unit {
  let __nl := io.print("")
  io.print("=== " + title + " ===")
}

fn print_position(sym :: Str, qty :: Int, price :: Int, limit :: Int) -> [io] Unit {
  let notional := qty * price
  let over     := notional - limit
  let tag := if over > 0 { "  *** BREACH " + usd(over) + " over limit ***" } else { "" }
  io.print("  " + sym + ":  " + format_commas(qty) + " shares  x  " + usd(price) + "  =  " + usd(notional) + tag)
}

# ---- Concurrent actor handlers ------------------------------------

fn trader_handler(state :: ActorState, _ :: ActorMsg) -> [sql, net, llm, time, crypto, concurrent] (ActorState, Str) {
  let ctx  := { db: state.db, log: state.log, max_steps: 10 }
  let goal := str.join([
    "You are a momentum equity trader. Your mandate: concentrate the portfolio into its ",
    "strongest performer by share count. ",
    "Observe current positions. Identify the symbol with the most shares. ",
    "Submit a BUY order for at least 5,000 shares of that symbol. ",
    "If the order is rejected, try the symbol with the next highest share count. ",
    "Call done as soon as one buy order is accepted by the OMS.",
  ], "")
  let decide := llm_decide.make_decide(state.provider, state.model, goal)
  let result := agent.run_with_llm(ctx, decide)
  let reply  := match result {
    GoalMet(r)          => r,
    StepLimitReached(n) => "step limit at " + int.to_str(n),
  }
  (state, reply)
}

fn compliance_handler(state :: ActorState, _ :: ActorMsg) -> [sql, net, llm, time, crypto, concurrent] (ActorState, Str) {
  let aapl_sell := 14286
  let msft_sell := 5953
  let ctx  := { db: state.db, log: state.log, max_steps: 15 }
  let goal := str.join([
    "You are an autonomous compliance officer. ",
    "Policy: MiFID II Article 57 — no single position may exceed $50,000,000 notional. ",
    "Risk engine findings:\n",
    "  AAPL 300,000 shares x $175 = $52,500,000  excess $2,500,000  corrective sell: 14,286 shares\n",
    "  MSFT 125,000 shares x $420 = $52,500,000  excess $2,500,000  corrective sell: 5,953 shares\n",
    "Remediation steps — execute in this exact order:\n",
    "1. Call observe with target=blotter. ",
    "   For every BUY order with state PendingNew: call cancel_order immediately. ",
    "   Use cl_ord_id='CXLRQ-' + the order's cl_ord_id, orig_cl_ord_id = the order's cl_ord_id, ",
    "   symbol = the order's symbol, side = 'buy'. ",
    "   Reason: no new positions may be opened while active compliance breaches exist.\n",
    "2. Submit a sell order: symbol=AAPL, quantity=" + int.to_str(aapl_sell) + ".\n",
    "3. Submit a sell order: symbol=MSFT, quantity=" + int.to_str(msft_sell) + ".\n",
    "4. Call done with a formal incident report that names:\n",
    "   — each breach (symbol, notional, excess),\n",
    "   — any orders cancelled and why,\n",
    "   — corrective sells executed and restored notionals.",
  ], "")
  let decide := llm_decide.make_decide(state.provider, state.model, goal)
  let result := agent.run_with_llm(ctx, decide)
  let reply  := match result {
    GoalMet(r)          => r,
    StepLimitReached(n) => "UNRESOLVED — monitor hit step limit (" + int.to_str(n) + " steps)",
  }
  (state, reply)
}

# ---- Demo ----------------------------------------------------------

fn run_demo(db :: conn.ConnDb, log :: trail_log.Log, provider :: prov.Provider, model :: prov.ModelRef) -> [sql, time, crypto, net, llm, io, concurrent] Unit {
  let __init := srv.init_db(db)
  let base_ctx := { db: db, log: log, max_steps: 10 }

  let aapl_px := 175
  let msft_px := 420
  let nvda_px := 875
  let limit   := 50000000

  # ── Phase 1: seed ───────────────────────────────────────────────
  let __h1 := print_section("PORTFOLIO  —  seed positions, all within limit")
  let __s  := agent.run(base_ctx, scripted_seed)
  let __f1 := simulate_seed_fills(db)
  let __p0 := io.print("  Policy: MiFID II Art. 57  |  Limit: " + usd(limit) + " max notional per name")
  let __l1 := print_position("AAPL", 200000, aapl_px, limit)
  let __l2 := print_position("MSFT",  80000, msft_px, limit)
  let __l3 := print_position("NVDA",  50000, nvda_px, limit)
  let __l4 := io.print("  NAV: " + usd(200000 * aapl_px + 80000 * msft_px + 50000 * nvda_px))

  # ── Phase 2: double rogue event ──────────────────────────────────
  let __h2 := print_section("INCIDENT  —  two rogue fills bypass OMS gate")
  let __f2 := simulate_rogue_fills(db)
  let __ra := io.print("  ROGUE-AAPL  +100,000 shares  →  injected via execution report")
  let __rb := io.print("  ROGUE-MSFT   +45,000 shares  →  injected via execution report")
  let aapl_qty := 300000
  let msft_qty := 125000
  let __la := print_position("AAPL", aapl_qty, aapl_px, limit)
  let __lb := print_position("MSFT", msft_qty, msft_px, limit)
  let __lc := print_position("NVDA",   50000,  nvda_px, limit)

  # ── Risk engine: breach computation (Lex arithmetic, not LLM) ────
  let aapl_notional := aapl_qty * aapl_px        # 52,500,000
  let msft_notional := msft_qty * msft_px        # 52,500,000
  let aapl_excess   := aapl_notional - limit     # 2,500,000
  let msft_excess   := msft_notional - limit     # 2,500,000
  # Ceiling division: ⌈excess / price⌉
  let aapl_sell := (aapl_excess + aapl_px - 1) / aapl_px   # 14,286
  let msft_sell := (msft_excess + msft_px - 1) / msft_px   #  5,953

  let __h_re := print_section("RISK ENGINE  —  corrective quantities (deterministic)")
  let __re1  := io.print("  AAPL  excess " + usd(aapl_excess) + "  →  sell " + format_commas(aapl_sell) + " shares  (position restored to " + usd(aapl_notional - aapl_sell * aapl_px) + ")")
  let __re2  := io.print("  MSFT  excess " + usd(msft_excess) + "  →  sell " + format_commas(msft_sell) + " shares  (position restored to " + usd(msft_notional - msft_sell * msft_px) + ")")
  let __re3  := io.print("  No LLM involved in this computation.")

  # ── Phase 3 & 4: spawn concurrent actors, interleaved round ─────
  let actor_state := { db: db, log: log, provider: provider, model: model }
  let trader     := conc.spawn(actor_state, trader_handler)
  let compliance := conc.spawn(actor_state, compliance_handler)

  # Round 1 — trader acts first, then compliance fires
  let __h3 := print_section("AGENT A  —  Momentum Trader  (actor)  [" + provider.name + " / " + model.model + "]")
  let trader_result := conc.ask(trader, Cycle(()))
  let __tp := io.print("  " + trader_result)
  let __tn := io.print("  NOTE: exchange fills NOT applied — the buy is PendingNew in the OMS blotter.")

  let __h4 := print_section("AGENT B  —  Compliance Monitor  (actor)  [" + provider.name + " / " + model.model + "]")
  let compliance_result := conc.ask(compliance, Cycle(()))

  # ── Incident report ───────────────────────────────────────────────
  let __h5 := print_section("COMPLIANCE INCIDENT REPORT")
  let __cp := io.print(compliance_result)

  # ── Blotter: shows cancelled trader buy alongside corrective sells ─
  let __h6 := print_section("BLOTTER  —  every order: seed · rogue · trader · monitor")
  let __bl := io.print((srv.get_blotter(db, get_ctx())).body)

  # ── Audit trail ───────────────────────────────────────────────────
  let __h7 := print_section("AUDIT TRAIL  —  hash-chained, tamper-evident")
  let __at := io.print((srv.get_audit(log, get_ctx())).body)
  let __ := io.print("")
  let __ := io.print("  Every entry above is content-addressed. The root hash of this chain")
  let __ := io.print("  is the 'id' field of the first entry. Altering any decision —")
  let __ := io.print("  even by one byte — invalidates the root and every hash that follows.")
  io.print("  Regulators verify independently. No party can rewrite history.")
}

fn main() -> [sql, time, crypto, net, llm, io, env, fs_write, concurrent, random, fs_read, proc] Unit {
  let vertex_proj := get_env("VERTEX_PROJECT")
  let anth_key    := get_env("ANTHROPIC_API_KEY")
  let has_vertex  := get_env("LLM_PROVIDER") == "vertex" or not str.is_empty(vertex_proj)
  let configured  := has_vertex or not str.is_empty(anth_key)
  if not configured {
    let __ := io.print("ERROR: no LLM provider configured.")
    let __ := io.print("  Set VERTEX_PROJECT=<gcp-project> for Vertex AI (uses gcloud ADC),")
    io.print("  or ANTHROPIC_API_KEY=<key> for Claude.")
  } else {
    let provider := select_provider()
    let model    := select_model()
    match conn.connect_sqlite(":memory:") {
      Err(e) => io.print("db error: " + dbe.message(e)),
      Ok(db) => match trail_log.open_memory() {
        Err(m) => io.print("trail error: " + m),
        Ok(log) => run_demo(db, log, provider, model),
      },
    }
  }
}

# lex-oms-agent — Demo 6: Real-Time Compliance Enforcement
#
# Three things no Python framework can guarantee:
#
#   1. EFFECT ISOLATION  — the compliance agent is declared [sql, llm].
#      It cannot touch the network, filesystem, or any other resource.
#      Not by accident. Not by a prompt injection. Proven at compile time.
#      (See examples/bad_agent.lex for the proof.)
#
#   2. LIVE ENFORCEMENT  — the compliance monitor intercepts the momentum
#      trader's pending BUY order before the exchange fills it.
#      The OMS is the single enforcement point. Both agents share it.
#      In production, run them as concurrent actors (conc.spawn) — the
#      monitor fires the moment a breach appears in the blotter.
#
#   3. TAMPER-EVIDENT CHAIN  — every decision is content-addressed and
#      hash-chained. No party can rewrite history. Regulators verify the
#      root hash independently, without trusting your infrastructure.
#
# Timeline:
#   1. Seed: AAPL $35M · MSFT $33.6M · NVDA $43.75M   NAV = $112,350,000
#   2. Double rogue (bypass OMS gate via execution reports):
#        AAPL +100,000 → 300,000 × $175 = $52,500,000  (+$2.5M breach)
#        MSFT  +45,000 → 125,000 × $420 = $52,500,000  (+$2.5M breach)
#   3. Risk engine (Lex, not LLM):
#        AAPL corrective sell: ⌈2,500,000 / 175⌉ = 14,286 shares
#        MSFT corrective sell: ⌈2,500,000 / 420⌉ =  5,953 shares
#   4. Momentum Trader (LLM):
#        Tries AAPL buy → OMS blocks (position already at $52.5M)
#        Tries MSFT buy → OMS blocks (position already at $52.5M)
#        Tries NVDA buy → accepted → PendingNew (exchange not yet notified)
#   5. Compliance Monitor (LLM):
#        Observes blotter → cancels trader's PendingNew NVDA buy
#        Submits AAPL corrective sell: 14,286 shares → accepted
#        Submits MSFT corrective sell:  5,953 shares → accepted
#        Files formal dual-breach incident report
#        NVDA buy never reaches the exchange.
#
# Run:
#   ANTHROPIC_API_KEY=sk-ant-... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/enforcement.lex main

import "std.io"   as io
import "std.list" as list
import "std.str"  as str
import "std.int"  as int
import "std.env"  as env
import "std.map"  as map

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

# ---- Provider selection --------------------------------------------

fn get_env(key :: Str) -> [env] Str {
  match env.get(key) { Some(v) => v, None => "" }
}

fn select_provider() -> [env] prov.Provider {
  match get_env("LLM_PROVIDER") {
    "vertex" => {
      let project      := get_env("VERTEX_PROJECT")
      let location     := get_env("VERTEX_LOCATION")
      let token        := get_env("VERTEX_ACCESS_TOKEN")
      let api_key      := get_env("VERTEX_API_KEY")
      let access_token := if str.is_empty(token) { api_key } else { token }
      let cfg := if str.is_empty(location) {
        vertex.default_config(access_token, project)
      } else {
        vertex.config_at(access_token, project, location)
      }
      vertex.make_provider(cfg)
    },
    _ => anth.make_provider(anth.default_config(get_env("ANTHROPIC_API_KEY"))),
  }
}

fn select_model() -> [env] prov.ModelRef {
  match get_env("LLM_PROVIDER") {
    "vertex" => {
      let m := get_env("VERTEX_MODEL")
      if str.is_empty(m) { vertex.gemini_35_flash() } else { { provider: "vertex", model: m } }
    },
    _ => {
      let m := get_env("ANTHROPIC_MODEL")
      if str.is_empty(m) { prov.claude_haiku() } else { { provider: "anthropic", model: m } }
    },
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

# ---- Demo ----------------------------------------------------------

fn run_demo(db :: conn.ConnDb, log :: trail_log.Log, provider :: prov.Provider, model :: prov.ModelRef) -> [sql, time, crypto, net, llm, io] Unit {
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

  # ── Phase 3: momentum trader ─────────────────────────────────────
  let __h3 := print_section("AGENT A  —  Momentum Trader  [" + provider.name + " / " + model.model + "]")
  let trader_goal := str.join([
    "You are a momentum equity trader. Your mandate: concentrate the portfolio into its ",
    "strongest performer by share count. ",
    "Observe current positions. Identify the symbol with the most shares. ",
    "Submit a BUY order for at least 5,000 shares of that symbol. ",
    "If the order is rejected, try the symbol with the next highest share count. ",
    "Call done as soon as one buy order is accepted by the OMS.",
  ], "")
  let trader_decide := llm_decide.make_decide(provider, model, trader_goal)
  let trader_ctx    := { db: db, log: log, max_steps: 15 }
  let trader_result := agent.run_with_llm(trader_ctx, trader_decide)
  let __tr := io.print("  " + match trader_result {
    GoalMet(r)          => "done: " + r,
    StepLimitReached(n) => "step limit at " + int.to_str(n),
  })
  let __tr2 := io.print("  NOTE: exchange fills NOT applied — the buy is PendingNew in the OMS blotter.")

  # ── Phase 4: compliance monitor ──────────────────────────────────
  let __h4 := print_section("AGENT B  —  Compliance Monitor  [" + provider.name + " / " + model.model + "]")

  let breach_data := str.join([
    "Risk engine findings:\n",
    "  AAPL  " + format_commas(aapl_qty) + " shares x " + usd(aapl_px) +
      " = " + usd(aapl_notional) + "  excess " + usd(aapl_excess) +
      "  corrective sell: " + format_commas(aapl_sell) + " shares\n",
    "  MSFT  " + format_commas(msft_qty) + " shares x " + usd(msft_px) +
      " = " + usd(msft_notional) + "  excess " + usd(msft_excess) +
      "  corrective sell: " + format_commas(msft_sell) + " shares\n",
  ], "")

  let monitor_goal := str.join([
    "You are an autonomous compliance officer. ",
    "Policy: MiFID II Article 57 — no single position may exceed $50,000,000 notional. ",
    breach_data,
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

  let monitor_decide := llm_decide.make_decide(provider, model, monitor_goal)
  let monitor_ctx    := { db: db, log: log, max_steps: 15 }
  let monitor_result := agent.run_with_llm(monitor_ctx, monitor_decide)

  # ── Incident report ───────────────────────────────────────────────
  let __h5 := print_section("COMPLIANCE INCIDENT REPORT")
  let __rep := io.print(match monitor_result {
    GoalMet(r)          => r,
    StepLimitReached(n) => "UNRESOLVED — monitor hit step limit (" + int.to_str(n) + " steps)",
  })

  # ── Blotter: shows cancelled trader buy alongside corrective sells ─
  let __h6 := print_section("BLOTTER  —  every order: seed · rogue · trader · monitor")
  let __bl := io.print((srv.get_blotter(db, get_ctx())).body)

  # ── Audit trail ───────────────────────────────────────────────────
  let __h7 := print_section("AUDIT TRAIL  —  hash-chained, tamper-evident")
  let __at := io.print((srv.get_audit(log, get_ctx())).body)
  io.print("")
  io.print("  Every entry above is content-addressed. The root hash of this chain")
  io.print("  is the 'id' field of the first entry. Altering any decision —")
  io.print("  even by one byte — invalidates the root and every hash that follows.")
  io.print("  Regulators verify independently. No party can rewrite history.")
}

fn main() -> [sql, time, crypto, net, llm, io, env, fs_write, concurrent, random, fs_read, proc] Unit {
  let provider := select_provider()
  let model    := select_model()
  match conn.connect_sqlite(":memory:") {
    Err(e)  => io.print("db error: " + dbe.message(e)),
    Ok(db)  => match trail_log.open_memory() {
      Err(m)  => io.print("trail error: " + m),
      Ok(log) => run_demo(db, log, provider, model),
    },
  }
}

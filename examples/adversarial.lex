# lex-oms-agent — Demo 4: Adversarial Agents
#
# Two LLM agents with opposing mandates act on the same portfolio
# through the same OMS. Neither is told about the other.
#
# Setup (scripted):
#   Seed 400 AAPL · 100 MSFT · 100 NVDA, then inject a rogue +200 AAPL
#   fill → positions hit 600 AAPL, above the 500-share policy limit.
#
# Agent A — Aggressive Trader:
#   Mandate: concentrate into the biggest holding. Sees 600 AAPL, buys
#   more. Its orders are immediately filled by the exchange simulation.
#
# Agent B — Risk Monitor:
#   Mandate: enforce the 500-share policy. Sees the deepened breach,
#   cancels any pending trader orders that would worsen it, and submits
#   corrective sell orders.
#
# The audit trail records both agents' decision chains on the same log.
#
# Run:
#   ANTHROPIC_API_KEY=sk-ant-... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/adversarial.lex main

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

fn symbol_px(sym :: Str) -> Str {
  match sym {
    "AAPL" => "175.00",
    "MSFT" => "420.00",
    "NVDA" => "875.00",
    _      => "100.00",
  }
}

fn fill_order(db :: conn.ConnDb, tag :: Str, cl_ord_id :: Str, sym :: Str, side :: Str, qty :: Int, px :: Str) -> [sql, time, crypto] Unit {
  let __a := srv.post_execution_reports(db, post_ctx(ack_json("EX-A-" + tag, "EXCH-" + tag, cl_ord_id, sym, side, qty)))
  let __f := srv.post_execution_reports(db, post_ctx(fill_json("EX-F-" + tag, "EXCH-" + tag, cl_ord_id, sym, side, qty, px)))
  ()
}

fn simulate_seed_fills(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  let __1 := fill_order(db, "S1", "SEED-AAPL", "AAPL", "buy", 400, "175.00")
  let __2 := fill_order(db, "S2", "SEED-MSFT", "MSFT", "buy", 100, "420.00")
  let __3 := fill_order(db, "S3", "SEED-NVDA", "NVDA", "buy", 100, "875.00")
  ()
}

fn simulate_rogue_fills(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  fill_order(db, "R1", "ROGUE-AAPL", "AAPL", "buy", 200, "175.00")
}

# Simulate exchange fills for every accepted SubmitOrder in a step history.
# Called after the trader runs so the monitor sees the true net position.
fn fill_history(db :: conn.ConnDb, history :: List[agent.Step]) -> [sql, time, crypto] Unit {
  let _ := list.fold(history, 0, fn (idx :: Int, step :: agent.Step) -> [sql, time, crypto] Int {
    let __ := if step.outcome.ok {
      match step.tool {
        SubmitOrder(p) => fill_order(db, "T" + int.to_str(idx), p.cl_ord_id, p.symbol, p.side, p.quantity, symbol_px(p.symbol)),
        _              => (),
      }
    } else { () }
    idx + 1
  })
  ()
}

# ---- Scripted agents -----------------------------------------------

fn scripted_seed(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 {
    SubmitOrder({ cl_ord_id: "SEED-AAPL", symbol: "AAPL", side: "buy", quantity: 400 })
  } else { if n == 1 {
    SubmitOrder({ cl_ord_id: "SEED-MSFT", symbol: "MSFT", side: "buy", quantity: 100 })
  } else { if n == 2 {
    SubmitOrder({ cl_ord_id: "SEED-NVDA", symbol: "NVDA", side: "buy", quantity: 100 })
  } else {
    AgentDone("seed complete")
  } } }
}

fn scripted_rogue(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 {
    SubmitOrder({ cl_ord_id: "ROGUE-AAPL", symbol: "AAPL", side: "buy", quantity: 200 })
  } else {
    AgentDone("rogue trade submitted")
  }
}

# ---- Utilities -----------------------------------------------------

fn print_section(title :: Str) -> [io] Unit {
  let __nl := io.print("")
  io.print("=== " + title + " ===")
}

fn result_str(r :: agent.AgentResult) -> Str {
  match r {
    GoalMet(reason)     => "done: " + reason,
    StepLimitReached(n) => "step limit at " + int.to_str(n),
  }
}

# ---- Demo ----------------------------------------------------------

fn run_demo(db :: conn.ConnDb, log :: trail_log.Log, provider :: prov.Provider, model :: prov.ModelRef) -> [sql, time, crypto, net, llm, io] Unit {
  let __init := srv.init_db(db)
  let base_ctx := { db: db, log: log, max_steps: 10 }

  # ── Scripted setup ──────────────────────────────────────────────
  let __h1 := print_section("PHASE 1 — Seed portfolio (scripted)")
  let __s  := agent.run(base_ctx, scripted_seed)
  let __f1 := simulate_seed_fills(db)
  let __ok := io.print("Seeded: 400 AAPL  100 MSFT  100 NVDA")

  let __h2 := print_section("PHASE 2 — Rogue trader doubles AAPL (scripted)")
  let __r  := agent.run(base_ctx, scripted_rogue)
  let __f2 := simulate_rogue_fills(db)
  let __ok2 := io.print("Rogue filled: +200 AAPL  →  total 600 AAPL  [BREACH: policy limit 500]")

  let __hpos := print_section("Positions before agents")
  let __pos0 := io.print((srv.get_positions(db, get_ctx())).body)

  # ── Agent A: Aggressive Trader ────────────────────────────────
  let __h3 := print_section("PHASE 3 — Agent A: Aggressive Trader  [" + provider.name + " / " + model.model + "]")
  let trader_goal := str.join([
    "You are an aggressive momentum trader. Your mandate: concentrate the portfolio into its strongest-performing position. ",
    "Observe current positions. Identify the symbol with the largest holding and submit a buy order to meaningfully ",
    "increase it — buy at least 100 shares. Call done once your buy order is accepted by the OMS.",
  ], "")
  let trader_decide := llm_decide.make_decide(provider, model, trader_goal)
  let trader_ctx    := { db: db, log: log, max_steps: 15 }
  let trader_run    := agent.run_with_llm_history(trader_ctx, trader_decide)
  let trader_result := match trader_run { (res, _hist) => res }
  let trader_hist   := match trader_run { (_res, hist) => hist }
  let __tr := io.print("Trader: " + result_str(trader_result))

  # Simulate exchange fills for the trader's accepted orders so
  # the monitor sees the true net position, not just PendingNew.
  let __hfill := print_section("Exchange fills trader orders")
  let __fills := fill_history(db, trader_hist)
  let __pos1  := io.print((srv.get_positions(db, get_ctx())).body)

  # ── Agent B: Risk Monitor ─────────────────────────────────────
  let __h4 := print_section("PHASE 4 — Agent B: Risk Monitor  [" + provider.name + " / " + model.model + "]")
  let monitor_goal := str.join([
    "You are a risk compliance monitor. Policy: no single symbol may exceed 500 shares. ",
    "First, call observe with target=blotter. Identify any pending BUY orders for symbols that are already ",
    "at or above the policy limit. Cancel each one with cancel_order to prevent it worsening the breach. ",
    "Then call observe with target=positions. For every symbol above 500 shares, submit a SELL order to ",
    "bring it back within limits. Call done when all breaching positions have corrective orders submitted.",
  ], "")
  let monitor_decide := llm_decide.make_decide(provider, model, monitor_goal)
  let monitor_ctx    := { db: db, log: log, max_steps: 20 }
  let monitor_result := agent.run_with_llm(monitor_ctx, monitor_decide)
  let __mr := io.print("Monitor: " + result_str(monitor_result))

  # ── Final state ───────────────────────────────────────────────
  let __h5 := print_section("Final Blotter (all orders: rogue · trader · monitor)")
  let __bl := io.print((srv.get_blotter(db, get_ctx())).body)

  let __h6 := print_section("Final Positions (trader fills applied; monitor sells pending)")
  let __p2 := io.print((srv.get_positions(db, get_ctx())).body)

  let __h7 := print_section("Audit Trail")
  io.print((srv.get_audit(log, get_ctx())).body)
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

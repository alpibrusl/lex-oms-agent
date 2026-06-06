# lex-oms-agent — Demo 2: LLM Risk Monitor
#
# Seeds a concentrated position (300 AAPL + 50 MSFT + 50 NVDA), then
# runs a scripted "rogue trader" that doubles down on AAPL (+300),
# pushing it to 600 shares — above the 500-share policy limit.
#
# An LLM risk-monitor agent then steps in: observes positions and risk,
# identifies the breach, submits sell orders to bring AAPL under 500,
# and diversifies by buying MSFT/NVDA.
#
# Flow:
#   1. Seed base portfolio + fills
#   2. Rogue trader doubles AAPL (scripted) + fills  → breach
#   3. Print risk showing concentration
#   4. LLM risk monitor observes and submits corrective orders
#   5. Show final blotter + risk + audit trail
#
# Run:
#   ANTHROPIC_API_KEY=sk-ant-... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/risk_monitor.lex main

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

import "../src/agent"              as agent
import "../src/anthropic_provider" as anth
import "../src/vertex_provider"    as vertex
import "../src/llm_decide"         as llm_decide
import "../src/tool"               as tool

# ---- Provider selection --------------------------------------------

fn get_env(key :: Str) -> [env] Str {
  match env.get(key) { Some(v) => v, None => "" }
}

fn select_provider() -> [env] prov.Provider {
  match get_env("LLM_PROVIDER") {
    "vertex" => {
      let project      := get_env("VERTEX_PROJECT")
      let location     := get_env("VERTEX_LOCATION")
      let token        := get_env("VERTEX_TOKEN")
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

fn fill_order(db :: conn.ConnDb, n :: Str, cl_ord_id :: Str, sym :: Str, side :: Str, qty :: Int, px :: Str) -> [sql, time, crypto] Unit {
  let __a := srv.post_execution_reports(db, post_ctx(ack_json("EX-A-" + n, "EXCH-" + n, cl_ord_id, sym, side, qty)))
  let __f := srv.post_execution_reports(db, post_ctx(fill_json("EX-F-" + n, "EXCH-" + n, cl_ord_id, sym, side, qty, px)))
  ()
}

fn simulate_base_fills(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  let __1 := fill_order(db, "B1", "BASE-AAPL", "AAPL", "buy", 300, "175.00")
  let __2 := fill_order(db, "B2", "BASE-MSFT", "MSFT", "buy",  50, "420.00")
  let __3 := fill_order(db, "B3", "BASE-NVDA", "NVDA", "buy",  50, "875.00")
  ()
}

fn simulate_rogue_fills(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  let __1 := fill_order(db, "R1", "ROGUE-AAPL-1", "AAPL", "buy", 200, "175.00")
  let __2 := fill_order(db, "R2", "ROGUE-AAPL-2", "AAPL", "buy", 100, "175.00")
  ()
}

# ---- Scripted agents -----------------------------------------------

fn scripted_base(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 {
    SubmitOrder({ cl_ord_id: "BASE-AAPL", symbol: "AAPL", side: "buy", quantity: 300 })
  } else { if n == 1 {
    SubmitOrder({ cl_ord_id: "BASE-MSFT", symbol: "MSFT", side: "buy", quantity: 50 })
  } else { if n == 2 {
    SubmitOrder({ cl_ord_id: "BASE-NVDA", symbol: "NVDA", side: "buy", quantity: 50 })
  } else {
    AgentDone("base seeded")
  } } }
}

fn scripted_rogue(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 {
    SubmitOrder({ cl_ord_id: "ROGUE-AAPL-1", symbol: "AAPL", side: "buy", quantity: 200 })
  } else { if n == 1 {
    SubmitOrder({ cl_ord_id: "ROGUE-AAPL-2", symbol: "AAPL", side: "buy", quantity: 100 })
  } else {
    AgentDone("rogue trades submitted")
  } }
}

# ---- Demo ----------------------------------------------------------

fn print_section(title :: Str) -> [io] Unit {
  let __nl := io.print("")
  io.print("=== " + title + " ===")
}

fn run_demo(db :: conn.ConnDb, log :: trail_log.Log, provider :: prov.Provider, model :: prov.ModelRef) -> [sql, time, crypto, net, llm, io] Unit {
  let __init := srv.init_db(db)
  let ctx    := { db: db, log: log, max_steps: 10 }

  let __h1  := print_section("PHASE 1 — Seed base portfolio (scripted)")
  let __sb  := agent.run(ctx, scripted_base)
  let __fb  := simulate_base_fills(db)
  let __ok1 := io.print("Seeded: 300 AAPL  50 MSFT  50 NVDA")

  let __h2  := print_section("PHASE 2 — Rogue trader doubles down on AAPL (scripted)")
  let __sr  := agent.run(ctx, scripted_rogue)
  let __fr  := simulate_rogue_fills(db)
  let __ok2 := io.print("Rogue added 300 more AAPL → total = 600 shares  [BREACH: policy limit 500]")

  let __h3  := print_section("Positions BEFORE monitor")
  let __p0  := io.print((srv.get_positions(db, get_ctx())).body)
  let __h3r := print_section("Risk BEFORE monitor")
  let __r0  := io.print((srv.get_risk(db, get_ctx())).body)

  let __h4   := print_section("PHASE 3 — LLM risk monitor  [provider=" + provider.name + "  model=" + model.model + "]")
  let goal   := str.join([
    "You are a risk monitoring agent. Risk policy: no single symbol may exceed 500 shares. ",
    "AAPL is currently at 600 shares — a breach of 100 shares over the 500-share limit. ",
    "Observe current positions. Submit a sell order to reduce AAPL to 400 shares (sell 200 AAPL). ",
    "Then improve diversification: buy 100 MSFT and 100 NVDA. ",
    "Observe final risk to confirm the breach is resolved. ",
    "Call done when AAPL is below the 500-share limit and diversification is improved.",
  ], "")
  let decide  := llm_decide.make_decide(provider, model, goal)
  let mon_ctx := { db: db, log: log, max_steps: 25 }
  let result  := agent.run_with_llm(mon_ctx, decide)

  let __res := io.print(match result {
    GoalMet(reason)     => "GoalMet: " + reason,
    StepLimitReached(n) => "StepLimitReached at step " + int.to_str(n),
  })

  let __h5 := print_section("Blotter (monitor orders — pending exchange fills)")
  let __bl := io.print((srv.get_blotter(db, get_ctx())).body)

  let __h6 := print_section("Risk AFTER monitor (orders submitted, fills pending)")
  let __r1 := io.print((srv.get_risk(db, get_ctx())).body)

  let __h7 := print_section("Audit trail")
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

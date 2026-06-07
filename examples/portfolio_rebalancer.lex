# lex-oms-agent — Demo 1: Autonomous Portfolio Rebalancer
#
# Seeds a skewed portfolio (700 AAPL, 150 MSFT, 50 NVDA) then turns an
# LLM agent loose to rebalance to equal 300-share weights per symbol.
#
# Flow:
#   1. Seed initial positions (scripted orders + exchange fill simulation)
#   2. Show initial positions
#   3. LLM agent observes, computes drift, submits rebalancing orders
#   4. Show blotter (new orders accepted) + audit trail
#
# Run:
#   ANTHROPIC_API_KEY=sk-ant-... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/portfolio_rebalancer.lex main
#
# For Vertex AI:
#   LLM_PROVIDER=vertex VERTEX_PROJECT=my-project VERTEX_ACCESS_TOKEN=ya29... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/portfolio_rebalancer.lex main

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

# ---- Fill simulation (seed positions) ------------------------------

fn ack_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"0\",\"ord_status\":\"0\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(qty) + "\",\"cum_qty\":\"0\",\"leaves_qty\":\"" + int.to_str(qty) + "\",\"avg_px\":\"0\",\"last_px\":\"\",\"last_qty\":\"\",\"text\":\"\"}"
}

fn fill_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int, px :: Str) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"2\",\"ord_status\":\"2\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(qty) + "\",\"cum_qty\":\"" + int.to_str(qty) + "\",\"leaves_qty\":\"0\",\"avg_px\":\"" + px + "\",\"last_px\":\"" + px + "\",\"last_qty\":\"" + int.to_str(qty) + "\",\"text\":\"\"}"
}

fn simulate_seed_fills(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  let __a1 := srv.post_execution_reports(db, post_ctx(ack_json("EX-A-S1", "EXCH-S1", "SEED-AAPL", "AAPL", "buy", 700)))
  let __f1 := srv.post_execution_reports(db, post_ctx(fill_json("EX-F-S1", "EXCH-S1", "SEED-AAPL", "AAPL", "buy", 700, "175.00")))
  let __a2 := srv.post_execution_reports(db, post_ctx(ack_json("EX-A-S2", "EXCH-S2", "SEED-MSFT", "MSFT", "buy", 150)))
  let __f2 := srv.post_execution_reports(db, post_ctx(fill_json("EX-F-S2", "EXCH-S2", "SEED-MSFT", "MSFT", "buy", 150, "420.00")))
  let __a3 := srv.post_execution_reports(db, post_ctx(ack_json("EX-A-S3", "EXCH-S3", "SEED-NVDA", "NVDA", "buy", 50)))
  let __f3 := srv.post_execution_reports(db, post_ctx(fill_json("EX-F-S3", "EXCH-S3", "SEED-NVDA", "NVDA", "buy", 50, "875.00")))
  ()
}

# ---- Seed scripted orders ------------------------------------------

fn scripted_seed(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 {
    SubmitOrder({ cl_ord_id: "SEED-AAPL", symbol: "AAPL", side: "buy", quantity: 700 })
  } else { if n == 1 {
    SubmitOrder({ cl_ord_id: "SEED-MSFT", symbol: "MSFT", side: "buy", quantity: 150 })
  } else { if n == 2 {
    SubmitOrder({ cl_ord_id: "SEED-NVDA", symbol: "NVDA", side: "buy", quantity: 50 })
  } else {
    AgentDone("seed complete")
  } } }
}

# ---- Demo ----------------------------------------------------------

fn print_section(title :: Str) -> [io] Unit {
  let __nl := io.print("")
  io.print("=== " + title + " ===")
}

fn run_demo(db :: conn.ConnDb, log :: trail_log.Log, provider :: prov.Provider, model :: prov.ModelRef) -> [sql, time, crypto, net, llm, io] Unit {
  let __init := srv.init_db(db)
  let seed_ctx := { db: db, log: log, max_steps: 10 }

  let __h1 := print_section("PHASE 1 — Seed skewed portfolio (scripted)")
  let __s   := agent.run(seed_ctx, scripted_seed)
  let __f   := simulate_seed_fills(db)
  let __ok  := io.print("Seeded: 700 AAPL  150 MSFT  50 NVDA  (exchange fills injected)")

  let __h2  := print_section("Initial positions")
  let __p0  := io.print((srv.get_positions(db, get_ctx())).body)

  let __h3  := print_section("PHASE 2 — LLM rebalancer  [provider=" + provider.name + "  model=" + model.model + "]")
  let goal  := str.join([
    "Rebalance the portfolio to equal weights: 300 shares each of AAPL, MSFT, and NVDA. ",
    "Current positions: AAPL 700 long, MSFT 150 long, NVDA 50 long. ",
    "To rebalance: sell 400 AAPL, buy 150 MSFT, buy 250 NVDA. ",
    "Observe positions first to confirm, then submit the three orders. ",
    "Call done once all three rebalancing orders are confirmed accepted by the OMS.",
  ], "")
  let decide  := llm_decide.make_decide(provider, model, goal)
  let run_ctx := { db: db, log: log, max_steps: 25 }
  let result  := agent.run_with_llm(run_ctx, decide)

  let __r := io.print(match result {
    GoalMet(reason)     => "GoalMet: " + reason,
    StepLimitReached(n) => "StepLimitReached at step " + int.to_str(n),
  })

  let __h4 := print_section("Blotter (rebalancing orders — pending exchange fills)")
  let __bl := io.print((srv.get_blotter(db, get_ctx())).body)

  let __h5 := print_section("Risk snapshot")
  let __ri := io.print((srv.get_risk(db, get_ctx())).body)

  let __h6 := print_section("Audit trail")
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

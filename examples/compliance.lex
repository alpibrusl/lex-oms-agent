# lex-oms-agent — Demo 5: Real-Time Compliance Monitor
#
# A $112M institutional equity portfolio.
# Internal policy, MiFID II Article 57 compliant:
#   no single position may exceed $50,000,000 notional exposure.
#
# Timeline:
#   1. Seed balanced portfolio — all within limit
#        AAPL 200,000 × $175 = $35,000,000
#        MSFT  80,000 × $420 = $33,600,000
#        NVDA  50,000 × $875 = $43,750,000  NAV = $112,350,000
#   2. Rogue event: unauthorised +100,000 AAPL fill injected
#        → AAPL 300,000 × $175 = $52,500,000  (BREACH +$2,500,000)
#   3. Compliance Monitor (LLM agent):
#        • observes positions
#        • identifies AAPL breach: $52.5M, excess $2.5M
#        • computes minimum corrective sell: ⌈2,500,000 / 175⌉ = 14,286 shares
#        • submits sell order — accepted by OMS
#        • files formal incident report
#
# The tamper-evident audit trail (lex-trail) records every decision with
# millisecond timestamps. Regulators can verify the full chain without
# trusting any single party.
#
# Run:
#   ANTHROPIC_API_KEY=sk-ant-... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/compliance.lex main

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

fn simulate_rogue_fills(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  fill_order(db, "R1", "ROGUE-AAPL", "AAPL", "buy", 100000)
}

fn fill_history(db :: conn.ConnDb, history :: List[agent.Step]) -> [sql, time, crypto] Unit {
  let _ := list.fold(history, 0, fn (idx :: Int, step :: agent.Step) -> [sql, time, crypto] Int {
    let __ := if step.outcome.ok {
      match step.tool {
        SubmitOrder(p) => fill_order(db, "T" + int.to_str(idx), p.cl_ord_id, p.symbol, p.side, p.quantity),
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
    SubmitOrder({ cl_ord_id: "SEED-AAPL", symbol: "AAPL", side: "buy", quantity: 200000 })
  } else { if n == 1 {
    SubmitOrder({ cl_ord_id: "SEED-MSFT", symbol: "MSFT", side: "buy", quantity: 80000 })
  } else { if n == 2 {
    SubmitOrder({ cl_ord_id: "SEED-NVDA", symbol: "NVDA", side: "buy", quantity: 50000 })
  } else {
    AgentDone("seed complete")
  } } }
}

fn scripted_rogue(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 {
    SubmitOrder({ cl_ord_id: "ROGUE-AAPL", symbol: "AAPL", side: "buy", quantity: 100000 })
  } else {
    AgentDone("rogue trade submitted")
  }
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

# ---- Portfolio display ---------------------------------------------

fn print_section(title :: Str) -> [io] Unit {
  let __nl := io.print("")
  io.print("=== " + title + " ===")
}

fn print_position(sym :: Str, qty :: Int, price :: Int, limit :: Int) -> [io] Unit {
  let notional := qty * price
  let over     := notional - limit
  let tag := if over > 0 {
    "  *** BREACH: " + usd(over) + " over limit ***"
  } else { "" }
  io.print("  " + sym + ": " + format_commas(qty) + " shares x " + usd(price) + " = " + usd(notional) + tag)
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
  let __h1 := print_section("PORTFOLIO — Seed positions (all within limit)")
  let __s  := agent.run(base_ctx, scripted_seed)
  let __f1 := simulate_seed_fills(db)
  let __p0 := io.print("  Policy: MiFID II Art. 57  |  Limit: " + usd(limit) + " max notional per name")
  let __l1 := print_position("AAPL", 200000, aapl_px, limit)
  let __l2 := print_position("MSFT",  80000, msft_px, limit)
  let __l3 := print_position("NVDA",  50000, nvda_px, limit)
  let __l4 := io.print("  NAV: " + usd(200000 * aapl_px + 80000 * msft_px + 50000 * nvda_px))

  # ── Phase 2: rogue event ─────────────────────────────────────────
  let __h2 := print_section("INCIDENT — Unauthorised trade detected")
  let __rr := agent.run(base_ctx, scripted_rogue)
  let __f2 := simulate_rogue_fills(db)
  let __ok := io.print("  Rogue fill: +100,000 AAPL @ $175")
  let __l5 := print_position("AAPL", 300000, aapl_px, limit)

  # ── Phase 3: compliance monitor ──────────────────────────────────
  let __h3 := print_section("AGENT — Compliance Monitor  [" + provider.name + " / " + model.model + "]")
  let monitor_goal := str.join([
    "You are an autonomous compliance officer for a $112,350,000 institutional equity fund. ",
    "Risk policy (MiFID II Article 57 compliant): no single position may exceed $50,000,000 notional. ",
    "Reference prices (use ONLY these — do not use prices from any risk endpoint): ",
    "  AAPL = $175 per share, MSFT = $420 per share, NVDA = $875 per share. ",
    "Step 1: call observe with target=positions. ",
    "For each symbol multiply shares by the reference price above to get notional. ",
    "Arithmetic example: 300,000 shares x $175 = $52,500,000. ",
    "Identify every symbol whose notional exceeds $50,000,000. ",
    "Step 2: for each breach, compute shares_to_sell = ceiling((notional - 50000000) / price). ",
    "Submit a sell order for exactly that many shares. ",
    "Step 3: call done with a formal compliance incident report in this exact format — ",
    "BREACH: [SYMBOL] [shares] shares x $[price] = $[notional]. ",
    "Excess: $[excess]. Corrective sell: [sold_shares] shares. ",
    "Position restored to $[final_notional]. Incident logged.",
  ], "")
  let monitor_decide := llm_decide.make_decide(provider, model, monitor_goal)
  let monitor_ctx    := { db: db, log: log, max_steps: 10 }
  let monitor_result := agent.run_with_llm(monitor_ctx, monitor_decide)

  # ── Output ────────────────────────────────────────────────────────
  let __h4 := print_section("COMPLIANCE INCIDENT REPORT")
  let __rep := io.print(match monitor_result {
    GoalMet(r)          => r,
    StepLimitReached(n) => "UNRESOLVED — monitor hit step limit (" + int.to_str(n) + " steps)",
  })

  let __h5 := print_section("Blotter  (seed · rogue · monitor)")
  let __bl := io.print((srv.get_blotter(db, get_ctx())).body)

  let __h6 := print_section("Audit Trail  (hash-chained · tamper-evident)")
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

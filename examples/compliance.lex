# lex-oms-agent — Demo 5: Dual-Breach Compliance Monitor
#
# $112M institutional equity portfolio governed by MiFID II Article 57:
# no single position may exceed $50,000,000 notional.
#
# Timeline:
#   1. Seed: AAPL $35M · MSFT $33.6M · NVDA $43.75M  (all within limit)
#   2. Double rogue event — two fills injected directly, bypassing the OMS gate:
#        AAPL +100,000 → 300,000 × $175 = $52,500,000  (+$2,500,000 breach)
#        MSFT  +45,000 → 125,000 × $420 = $52,500,000  (+$2,500,000 breach)
#   3. Lex risk engine computes corrective quantities deterministically:
#        AAPL: ⌈2,500,000 / 175⌉ = 14,286 shares to sell
#        MSFT: ⌈2,500,000 / 420⌉ =  5,953 shares to sell
#      These figures are passed into the agent — the LLM does no arithmetic.
#   4. Compliance Monitor (LLM agent):
#        • observes blotter — cancels any pending buys for breached symbols
#        • submits two corrective sell orders (exact quantities from risk engine)
#        • files a formal dual-breach incident report
#
# Design principle: the risk engine owns the math; the agent owns the decisions.
# The tamper-evident audit trail (lex-trail) records every step for regulators.
#
# Run:
#   ANTHROPIC_API_KEY=sk-ant-... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/compliance.lex main

import "std.io" as io

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.env" as env

import "std.map" as map

import "lex-orm/src/connection" as conn

import "lex-orm/src/error" as dbe

import "lex-trail/src/log" as trail_log

import "lex-llm/provider" as prov

import "lex-oms/src/server" as srv

import "../src/agent" as agent

import "lex-llm/src/providers/anthropic" as anth

import "lex-llm/src/providers/vertex" as vertex

import "../src/llm_decide" as llm_decide

import "../src/tool" as tool

# ---- Provider selection --------------------------------------------
fn get_env(key :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => v,
    None => "",
  }
}

fn select_provider() -> [env] prov.Provider {
  match get_env("LLM_PROVIDER") {
    "vertex" => {
      let project := get_env("VERTEX_PROJECT")
      let location := get_env("VERTEX_LOCATION")
      let token := get_env("VERTEX_ACCESS_TOKEN")
      let api_key := get_env("VERTEX_API_KEY")
      let access_token := if str.is_empty(token) {
        api_key
      } else {
        token
      }
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
      if str.is_empty(m) {
        vertex.gemini_35_flash()
      } else {
        { provider: "vertex", model: m }
      }
    },
    _ => {
      let m := get_env("ANTHROPIC_MODEL")
      if str.is_empty(m) {
        prov.claude_haiku()
      } else {
        { provider: "anthropic", model: m }
      }
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
  match sym {
    "AAPL" => "175.00",
    "MSFT" => "420.00",
    "NVDA" => "875.00",
    _ => "100.00",
  }
}

fn fill_order(db :: conn.ConnDb, tag :: Str, cl_ord_id :: Str, sym :: Str, side :: Str, qty :: Int) -> [sql, time, crypto] Unit {
  let __a := srv.post_execution_reports(db, post_ctx(ack_json("EX-A-" + tag, "EXCH-" + tag, cl_ord_id, sym, side, qty)))
  let __f := srv.post_execution_reports(db, post_ctx(fill_json("EX-F-" + tag, "EXCH-" + tag, cl_ord_id, sym, side, qty, symbol_px_str(sym))))
  ()
}

fn simulate_seed_fills(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  let __1 := fill_order(db, "S1", "SEED-AAPL", "AAPL", "buy", 200000)
  let __2 := fill_order(db, "S2", "SEED-MSFT", "MSFT", "buy", 80000)
  let __3 := fill_order(db, "S3", "SEED-NVDA", "NVDA", "buy", 50000)
  ()
}

# Both rogue fills bypass the OMS gate via direct execution report injection.
fn simulate_rogue_fills(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  let __1 := fill_order(db, "R1", "ROGUE-AAPL", "AAPL", "buy", 100000)
  let __2 := fill_order(db, "R2", "ROGUE-MSFT", "MSFT", "buy", 45000)
  ()
}

# ---- Scripted seed agent -------------------------------------------
fn scripted_seed(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 {
    SubmitOrder({ cl_ord_id: "SEED-AAPL", symbol: "AAPL", side: "buy", quantity: 200000 })
  } else {
    if n == 1 {
      SubmitOrder({ cl_ord_id: "SEED-MSFT", symbol: "MSFT", side: "buy", quantity: 80000 })
    } else {
      if n == 2 {
        SubmitOrder({ cl_ord_id: "SEED-NVDA", symbol: "NVDA", side: "buy", quantity: 50000 })
      } else {
        AgentDone("seed complete")
      }
    }
  }
}

# ---- Dollar formatting ---------------------------------------------
fn pad3(n :: Int) -> Str {
  if n < 10 {
    "00" + int.to_str(n)
  } else {
    if n < 100 {
      "0" + int.to_str(n)
    } else {
      int.to_str(n)
    }
  }
}

fn format_commas(n :: Int) -> Str {
  let m := n / 1000000
  let r := n - m * 1000000
  let t := r / 1000
  let o := r - t * 1000
  if m > 0 {
    int.to_str(m) + "," + pad3(t) + "," + pad3(o)
  } else {
    if t > 0 {
      int.to_str(t) + "," + pad3(o)
    } else {
      int.to_str(o)
    }
  }
}

fn usd(n :: Int) -> Str {
  "$" + format_commas(n)
}

# ---- Portfolio display ---------------------------------------------
fn print_section(title :: Str) -> [io] Unit {
  let __nl := io.print("")
  io.print("=== " + title + " ===")
}

fn print_position(sym :: Str, qty :: Int, price :: Int, limit :: Int) -> [io] Unit {
  let notional := qty * price
  let over := notional - limit
  let tag := if over > 0 {
    "  *** BREACH: " + usd(over) + " over limit ***"
  } else {
    ""
  }
  io.print("  " + sym + ": " + format_commas(qty) + " shares x " + usd(price) + " = " + usd(notional) + tag)
}

# ---- Demo ----------------------------------------------------------
fn run_demo(db :: conn.ConnDb, log :: trail_log.Log, provider :: prov.Provider, model :: prov.ModelRef) -> [sql, time, crypto, net, llm, io] Unit {
  let __init := srv.init_db(db)
  let base_ctx := { db: db, log: log, max_steps: 10, clock: ClockWall }
  let aapl_px := 175
  let msft_px := 420
  let nvda_px := 875
  let limit := 50000000
  let __h1 := print_section("PORTFOLIO — Seed positions (all within limit)")
  let __s := agent.run(base_ctx, scripted_seed)
  let __f1 := simulate_seed_fills(db)
  let __p0 := io.print("  Policy: MiFID II Art. 57  |  Limit: " + usd(limit) + " max notional per name")
  let __l1 := print_position("AAPL", 200000, aapl_px, limit)
  let __l2 := print_position("MSFT", 80000, msft_px, limit)
  let __l3 := print_position("NVDA", 50000, nvda_px, limit)
  let __l4 := io.print("  NAV: " + usd(200000 * aapl_px + 80000 * msft_px + 50000 * nvda_px))
  let __h2 := print_section("INCIDENT — Unauthorised fills injected (bypass OMS gate)")
  let __f2 := simulate_rogue_fills(db)
  let aapl_qty := 300000
  let msft_qty := 125000
  let __ra := io.print("  ROGUE-AAPL: +100,000 shares injected")
  let __rb := io.print("  ROGUE-MSFT:  +45,000 shares injected")
  let __la := print_position("AAPL", aapl_qty, aapl_px, limit)
  let __lb := print_position("MSFT", msft_qty, msft_px, limit)
  let __lc := print_position("NVDA", 50000, nvda_px, limit)
  let aapl_notional := aapl_qty * aapl_px
  let msft_notional := msft_qty * msft_px
  let aapl_excess := aapl_notional - limit
  let msft_excess := msft_notional - limit
  let aapl_sell := (aapl_excess + aapl_px - 1) / aapl_px
  let msft_sell := (msft_excess + msft_px - 1) / msft_px
  let breach_report := str.join(["Risk engine report — 2 MiFID II Art. 57 breaches:\n", "  AAPL  " + format_commas(aapl_qty) + " shares x " + usd(aapl_px) + " = " + usd(aapl_notional) + "  excess " + usd(aapl_excess) + "  corrective sell: " + format_commas(aapl_sell) + " shares\n", "  MSFT  " + format_commas(msft_qty) + " shares x " + usd(msft_px) + " = " + usd(msft_notional) + "  excess " + usd(msft_excess) + "  corrective sell: " + format_commas(msft_sell) + " shares\n"], "")
  let __h3 := print_section("AGENT — Compliance Monitor  [" + provider.name + " / " + model.model + "]")
  let __br := io.print(breach_report)
  let monitor_goal := str.join(["You are an autonomous compliance officer. ", "Policy: MiFID II Article 57 — no single position may exceed $50,000,000 notional. ", "The risk engine has identified the following breaches:\n", breach_report, "Execute remediation in this order:\n", "1. Call observe with target=blotter. ", "   Cancel any open BUY orders for AAPL or MSFT using cancel_order.\n", "2. Submit a sell order: symbol=AAPL, quantity=" + int.to_str(aapl_sell) + ".\n", "3. Submit a sell order: symbol=MSFT, quantity=" + int.to_str(msft_sell) + ".\n", "4. Call done with a formal incident report that names both symbols, ", "the breach amounts, corrective sells, and restored notionals."], "")
  let monitor_decide := llm_decide.make_decide(provider, model, monitor_goal)
  let monitor_ctx := { db: db, log: log, max_steps: 12, clock: ClockWall }
  let monitor_result := agent.run_with_llm(monitor_ctx, monitor_decide)
  let __h4 := print_section("COMPLIANCE INCIDENT REPORT")
  let __rep := io.print(match monitor_result {
    GoalMet(r) => r,
    StepLimitReached(n) => "UNRESOLVED — monitor hit step limit (" + int.to_str(n) + " steps)",
  })
  let __h5 := print_section("Blotter  (seed · rogue · monitor)")
  let __bl := io.print(srv.get_blotter(db, get_ctx()).body)
  let __h6 := print_section("Audit Trail  (hash-chained · tamper-evident)")
  io.print(srv.get_audit(log, get_ctx()).body)
}

fn main() -> [sql, time, crypto, net, llm, io, env, fs_write, concurrent, random, fs_read, proc] Unit {
  let provider := select_provider()
  let model := select_model()
  match conn.connect_sqlite(":memory:") {
    Err(e) => io.print("db error: " + dbe.message(e)),
    Ok(db) => match trail_log.open_memory() {
      Err(m) => io.print("trail error: " + m),
      Ok(log) => run_demo(db, log, provider, model),
    },
  }
}


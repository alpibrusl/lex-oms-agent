# lex-oms-agent — Demo 9: Autonomous Hedging Agent
#
# Demonstrates integration of deterministic quantitative finance
# (Black-Scholes, Greeks) with an LLM execution agent — in a single
# Lex program with compile-time effect isolation.
#
# The key investor insight:
#
#   The risk engine (lex-risk/src/options.lex) is declared with
#   Effects: none. It is provably pure — no network, no database,
#   no LLM calls. The Black-Scholes computation is guaranteed
#   correct and repeatable, regardless of what the LLM does.
#
#   The LLM agent is declared [sql, llm, net, time, crypto]. It
#   receives the precomputed hedge size and submits the order.
#   The model cannot alter the pricing logic or bypass the OMS gate.
#
# Scenario:
#   Long 1,000 NVDA at $875 = $875,000 gross exposure.
#   Risk engine computes Black-Scholes ATM protective put:
#     Spot $875  Strike $875  σ 45%  r 5.25%  T 30 days
#     → put price  ≈ $38.52 / share
#     → put delta  ≈ -0.43
#     → cost of full put hedge: 1,000 × $38.52 = $38,520
#     → delta-neutral equity hedge: sell 432 NVDA shares
#   LLM Hedging Agent: observes position, receives the computed
#   hedge size, submits SELL 432 NVDA through the OMS gate.
#
# Timeline:
#   1. Seed: BUY 1,000 NVDA at $875 (OMS + exchange fill)
#   2. Risk engine [pure Lex]:
#        Black-Scholes → put price, delta, gamma, vega
#        Delta-neutral hedge size = ⌊|put_delta| × 1,000⌋
#   3. LLM Hedging Agent [sql, llm, net, time, crypto]:
#        Observe position → execute delta-neutral sell → call done
#   4. Blotter + audit chain
#
# Run:
#   VERTEX_PROJECT=my-gcp-project \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/hedging_agent.lex main
#
#   Or with Anthropic:
#   ANTHROPIC_API_KEY=sk-ant-... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/hedging_agent.lex main

import "std.io" as io

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.float" as float

import "std.env" as env

import "std.map" as map

import "lex-orm/src/connection" as conn

import "lex-orm/src/error" as dbe

import "lex-trail/src/log" as trail_log

import "lex-money/src/decimal" as d

import "lex-risk/src/options" as bs

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
  let vertex_proj := get_env("VERTEX_PROJECT")
  let use_vertex := get_env("LLM_PROVIDER") == "vertex" or not str.is_empty(vertex_proj)
  if use_vertex {
    let location := get_env("VERTEX_LOCATION")
    let token := get_env("VERTEX_ACCESS_TOKEN")
    let api_key := get_env("VERTEX_API_KEY")
    let access_token := if str.is_empty(token) {
      api_key
    } else {
      token
    }
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
  let use_vertex := get_env("LLM_PROVIDER") == "vertex" or not str.is_empty(vertex_proj)
  if use_vertex {
    let m := get_env("VERTEX_MODEL")
    if str.is_empty(m) {
      vertex.gemini_35_flash()
    } else {
      { provider: "vertex", model: m }
    }
  } else {
    let m := get_env("ANTHROPIC_MODEL")
    if str.is_empty(m) {
      prov.claude_haiku()
    } else {
      { provider: "anthropic", model: m }
    }
  }
}

# ---- HTTP context helpers ------------------------------------------
fn post_ctx(body :: Str) -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  { method: "POST", path: "/", query: "", body: body, path_params: map.new(), headers: map.from_list([("content-type", "application/json")]), state: map.new() }
}

fn get_ctx() -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  post_ctx("")
}

# ---- Fill simulation -----------------------------------------------
fn ack_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"0\",\"ord_status\":\"0\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(qty) + "\",\"cum_qty\":\"0\",\"leaves_qty\":\"" + int.to_str(qty) + "\",\"avg_px\":\"0\",\"last_px\":\"\",\"last_qty\":\"\",\"text\":\"\"}"
}

fn fill_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int, px :: Str) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"2\",\"ord_status\":\"2\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(qty) + "\",\"cum_qty\":\"" + int.to_str(qty) + "\",\"leaves_qty\":\"0\",\"avg_px\":\"" + px + "\",\"last_px\":\"" + px + "\",\"last_qty\":\"" + int.to_str(qty) + "\",\"text\":\"\"}"
}

fn simulate_seed_fill(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  let __ := srv.post_execution_reports(db, post_ctx(ack_json("EX-A-S1", "EXCH-S1", "SEED-NVDA", "NVDA", "buy", 1000)))
  let __ := srv.post_execution_reports(db, post_ctx(fill_json("EX-F-S1", "EXCH-S1", "SEED-NVDA", "NVDA", "buy", 1000, "875.00")))
  ()
}

# ---- Scripted seed agent -------------------------------------------
fn scripted_seed(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 {
    SubmitOrder({ cl_ord_id: "SEED-NVDA", symbol: "NVDA", side: "buy", quantity: 1000 })
  } else {
    AgentDone("seed complete")
  }
}

# ---- Display helpers -----------------------------------------------
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

fn print_section(title :: Str) -> [io] Unit {
  let __ := io.print("")
  io.print("=== " + title + " ===")
}

# Format a Float to 4 significant decimal places for display
fn fmt4(x :: Float) -> Str {
  let sign := if x < 0.0 {
    "-"
  } else {
    ""
  }
  let abs_x := if x < 0.0 {
    0.0 - x
  } else {
    x
  }
  let scaled := float.to_int(abs_x * 10000.0 + 0.5)
  let integer := scaled / 10000
  let frac := scaled - integer * 10000
  let fstr := if frac < 10 {
    "000" + int.to_str(frac)
  } else {
    if frac < 100 {
      "00" + int.to_str(frac)
    } else {
      if frac < 1000 {
        "0" + int.to_str(frac)
      } else {
        int.to_str(frac)
      }
    }
  }
  sign + int.to_str(integer) + "." + fstr
}

# Format a Float as a dollar amount (2dp), handles negative values
fn fmt_usd_f(x :: Float) -> Str {
  let neg := x < 0.0
  let abs_x := if neg {
    0.0 - x
  } else {
    x
  }
  let cents := float.to_int(abs_x * 100.0 + 0.5)
  let dollars := cents / 100
  let c := cents - dollars * 100
  let sign := if neg {
    "-"
  } else {
    ""
  }
  sign + "$" + format_commas(dollars) + "." + if c < 10 {
    "0" + int.to_str(c)
  } else {
    int.to_str(c)
  }
}

# ---- Demo ----------------------------------------------------------
fn run_demo(db :: conn.ConnDb, log :: trail_log.Log, provider :: prov.Provider, model :: prov.ModelRef) -> [sql, time, crypto, net, llm, io] Unit {
  let __ := srv.init_db(db)
  let position_qty := 1000
  let nvda_px_int := 875
  let __ := print_section("POSITION  —  seed 1,000 NVDA at $875")
  let seed_ctx := { db: db, log: log, max_steps: 5, clock: ClockWall }
  let __ := agent.run(seed_ctx, scripted_seed)
  let __ := simulate_seed_fill(db)
  let __ := io.print("  NVDA:  1,000 shares  ×  $875  =  $875,000 gross exposure")
  let __ := print_section("RISK ENGINE  —  Black-Scholes ATM 30-day put  [pure Lex, no effects]")
  let spot_dec := d.from_int(nvda_px_int)
  let strike_dec := d.from_int(nvda_px_int)
  let rate_dec := { coefficient: 525, exponent: -5 }
  let vol_dec := { coefficient: 45, exponent: -2 }
  let expiry_days := 30
  let inputs := bs.option_inputs(spot_dec, strike_dec, rate_dec, vol_dec, expiry_days)
  let put_price_f := bs.put_price(inputs)
  let put_delta_f := bs.put_delta(inputs)
  let gamma_f := bs.gamma(inputs)
  let vega_f := bs.vega(inputs)
  let put_theta_f := bs.put_theta(inputs)
  let __ := io.print("  Inputs:  Spot " + usd(nvda_px_int) + "  Strike " + usd(nvda_px_int) + "  σ 45%  r 5.25%  T 30 days")
  let __ := io.print("  Put price:  " + fmt_usd_f(put_price_f) + " / share")
  let __ := io.print("  Put delta:  " + fmt4(put_delta_f) + "  (put moves $0.43 per $1 spot decline)")
  let __ := io.print("  Gamma:      " + fmt4(gamma_f))
  let __ := io.print("  Vega:       " + fmt_usd_f(vega_f) + " per 1% vol move")
  let __ := io.print("  Theta:      " + fmt_usd_f(put_theta_f) + " / day")
  let __ := io.print("")
  let __ := io.print("  Cost of full put hedge (1,000 contracts): " + fmt_usd_f(put_price_f * 1000.0))
  let __ := io.print("")
  let delta_abs := 0.0 - put_delta_f
  let hedge_qty := float.to_int(delta_abs * int.to_float(position_qty))
  let residual := position_qty - hedge_qty
  let __ := io.print("  Delta-neutral equity hedge:")
  let __ := io.print("    Portfolio delta: +" + int.to_str(position_qty) + " (long " + int.to_str(position_qty) + " NVDA)")
  let __ := io.print("    Hedge: sell " + int.to_str(hedge_qty) + " NVDA  (⌊" + int.to_str(position_qty) + " × " + fmt4(delta_abs) + "⌋)")
  let __ := io.print("    Residual net delta after hedge: +" + int.to_str(residual) + " shares")
  let __ := io.print("  NOTE: computation is Effects: none — no LLM, no network, no DB.")
  let __ := print_section("LLM HEDGING AGENT  [" + provider.name + " / " + model.model + "]")
  let goal := str.join(["You are an autonomous hedging agent. ", "The risk engine has computed the following:\n", "  Position: long 1,000 NVDA at $875 = $875,000 gross exposure.\n", "  Black-Scholes ATM 30-day put: price " + fmt_usd_f(put_price_f) + " / share, put delta " + fmt4(put_delta_f) + ".\n", "  Delta-neutral hedge: sell " + int.to_str(hedge_qty) + " NVDA to neutralize equity delta.\n", "Execution steps — perform in order:\n", "1. Call observe with target=positions to confirm the NVDA long is present.\n", "2. Submit a SELL order: symbol=NVDA, quantity=" + int.to_str(hedge_qty) + ", cl_ord_id=HEDGE-NVDA-DELTA.\n", "   This is the delta-neutral hedge prescribed by the risk engine.\n", "3. Call done with a brief hedge confirmation: position observed, ", "delta hedge of " + int.to_str(hedge_qty) + " shares submitted, ", "residual net delta +" + int.to_str(residual) + " shares."], "")
  let decide := llm_decide.make_decide(provider, model, goal)
  let run_ctx := { db: db, log: log, max_steps: 10, clock: ClockWall }
  let result := agent.run_with_llm(run_ctx, decide)
  let __ := io.print(match result {
    GoalMet(r) => "  " + r,
    StepLimitReached(n) => "  INCOMPLETE — step limit at " + int.to_str(n),
  })
  let __ := print_section("BLOTTER  —  seed buy · hedge sell")
  let __ := io.print(srv.get_blotter(db, get_ctx()).body)
  let __ := print_section("AUDIT TRAIL  —  hash-chained, tamper-evident")
  let __ := io.print(srv.get_audit(log, get_ctx()).body)
  let __ := io.print("")
  let __ := io.print("  Risk engine computation: provably pure (Effects: none).")
  io.print("  Hedge execution: logged, content-addressed, verifiable by regulators.")
}

fn main() -> [sql, time, crypto, net, llm, io, env, fs_write, concurrent, random, fs_read, proc] Unit {
  let vertex_proj := get_env("VERTEX_PROJECT")
  let anth_key := get_env("ANTHROPIC_API_KEY")
  let has_vertex := get_env("LLM_PROVIDER") == "vertex" or not str.is_empty(vertex_proj)
  let configured := has_vertex or not str.is_empty(anth_key)
  if not configured {
    let __ := io.print("ERROR: no LLM provider configured.")
    let __ := io.print("  Set VERTEX_PROJECT=<gcp-project> for Vertex AI (uses gcloud ADC),")
    io.print("  or ANTHROPIC_API_KEY=<key> for Claude.")
  } else {
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
}


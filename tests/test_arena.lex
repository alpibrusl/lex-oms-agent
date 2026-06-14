# lex-arena tests — end-to-end replay verification
#
# The full arena loop in memory: run an episode → serialize the trail →
# parse it back → extract decisions → replay → compare. Then the
# adversarial case: tamper with a decision and assert the replay
# diverges. No files involved — pure in-memory round-trip.
#
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#     tests/test_arena.lex arena_main

import "std.str" as str
import "std.int" as int
import "std.list" as list

import "lex-money/src/decimal" as d
import "lex-positions/src/position" as pos

import "../src/agent" as agent
import "../src/tool" as tool
import "../src/arena/scenario" as scenario
import "../src/arena/trail_file" as tf
import "../src/arena/episode" as episode
import "../src/arena/verify" as verify
import "../src/arena/fills" as fills

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond { Ok(()) } else { Err(name) }
}

fn test_scenario() -> scenario.Scenario {
  { version: "2", name: "test-ep", seed: 7, episode_start_ms: 1700000000000, tick_ms: 1000, max_steps: 20, instruments: [{ symbol: "AAPL", prices: "100.00,101.50,103.00" }], cost: { spread_bps: 0, impact_bps: 0, lot: 1, fee_bps: 0, fee_per_unit_cents: 0 } }
}

fn strategy(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 { Observe(Blotter) }
  else { if n == 1 { SubmitOrder({ cl_ord_id: "T-001", symbol: "AAPL", side: "buy", quantity: 100 }) }
  else { AgentDone("done") } }
}

# Round-trip: episode → jsonl → parse → decisions → replay → identical.
fn t_verified_roundtrip() -> [sql, time, crypto, fs_write] Result[Unit, Str] {
  let sc := test_scenario()
  match episode.run_episode(sc, strategy) {
    Err(e) => Err("episode failed: " + e),
    Ok(out) => {
      let jsonl := tf.to_jsonl(out.lines)
      match tf.parse_jsonl(jsonl) {
        Err(e) => Err("parse failed: " + e),
        Ok(submitted) => match verify.extract_decisions(submitted) {
          Err(e) => Err("extract failed: " + e),
          Ok(decisions) => {
            let done_reason := verify.extract_done_reason(submitted)
            match verify.run_replay(sc, decisions, done_reason) {
              Err(e) => Err("replay failed: " + e),
              Ok(replayed) => {
                let div := verify.first_divergence(submitted, replayed.lines)
                check("honest trail verifies (divergence = -1, got " + int.to_str(div) + ")", div == -1)
              },
            }
          },
        },
      }
    },
  }
}

# Tamper: change a decision's quantity in the serialized trail; the
# replay must diverge (the content hashes cannot match).
fn t_tampered_rejected() -> [sql, time, crypto, fs_write] Result[Unit, Str] {
  let sc := test_scenario()
  match episode.run_episode(sc, strategy) {
    Err(e) => Err("episode failed: " + e),
    Ok(out) => {
      let jsonl := tf.to_jsonl(out.lines)
      let doctored := str.replace(jsonl, "\\\"quantity\\\":100", "\\\"quantity\\\":99999")
      match tf.parse_jsonl(doctored) {
        Err(e) => Err("parse failed: " + e),
        Ok(submitted) => match verify.extract_decisions(submitted) {
          Err(e) => Err("extract failed: " + e),
          Ok(decisions) => {
            let done_reason := verify.extract_done_reason(submitted)
            match verify.run_replay(sc, decisions, done_reason) {
              Err(e) => Err("replay failed: " + e),
              Ok(replayed) => {
                let div := verify.first_divergence(submitted, replayed.lines)
                check("tampered trail must diverge", div >= 0)
              },
            }
          },
        },
      }
    },
  }
}

# Scenario id is content-addressed: any field change changes the id.
fn t_scenario_id_content_addressed() -> Result[Unit, Str] {
  let a := test_scenario()
  let b := { version: "2", name: "test-ep", seed: 8, episode_start_ms: 1700000000000, tick_ms: 1000, max_steps: 20, instruments: [{ symbol: "AAPL", prices: "100.00,101.50,103.00" }], cost: { spread_bps: 0, impact_bps: 0, lot: 1, fee_bps: 0, fee_per_unit_cents: 0 } }
  check("seed participates in scenario id", scenario.scenario_id(a) != scenario.scenario_id(b))
}

# P&L: strategy buys 100 AAPL at step 1 (price 101.50); episode mark is
# 103.00 → pnl = 100 * 1.50 = 150.00. Pure function of (trail, scenario).
fn t_pnl_from_trail() -> [sql, time, crypto, fs_write] Result[Unit, Str] {
  let sc := test_scenario()
  match episode.run_episode(sc, strategy) {
    Err(e) => Err("episode failed: " + e),
    Ok(out) => {
      let pnl := fills.pnl_str(sc, out.lines)
      let notional := fills.notional_str(sc, out.lines)
      if pnl == "150.00" {
        if notional == "10150.00" {
          check("fill count", fills.fill_count(out.lines) == 1)
        } else {
          Err("expected notional 10150.00, got " + notional)
        }
      } else {
        Err("expected pnl 150.00, got " + pnl)
      }
    },
  }
}

# A position-notional breach: 600,000 AAPL @ ~100 ≈ $60M > the $50M cap,
# but under the 1M qty cap. With live marks seeded from the scenario the
# OMS rejects it (and logs trade.order.rejected); it must not fill.
fn breach_strategy(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 { Observe(Blotter) }
  else { if n == 1 { SubmitOrder({ cl_ord_id: "BIG-1", symbol: "AAPL", side: "buy", quantity: 600000 }) }
  else { AgentDone("notional breach") } }
}

fn count_kind(lines :: List[tf.Line], k :: Str) -> Int {
  list.fold(lines, 0, fn (acc :: Int, l :: tf.Line) -> Int {
    if l.kind == k { acc + 1 } else { acc }
  })
}

fn t_notional_breach_rejected() -> [sql, time, crypto, fs_write] Result[Unit, Str] {
  let sc := test_scenario()
  match episode.run_episode(sc, breach_strategy) {
    Err(e) => Err("episode failed: " + e),
    Ok(out) => {
      let rejected := count_kind(out.lines, "trade.order.rejected")
      if rejected >= 1 {
        check("notional breach must not fill", fills.fill_count(out.lines) == 0)
      } else {
        Err("expected a trade.order.rejected event for the notional breach, got 0")
      }
    },
  }
}

# ---- cost model (spread + slippage) ---------------------------------

fn cost_scenario(spread :: Int, impact :: Int, lot :: Int) -> scenario.Scenario {
  { version: "2", name: "cost-ep", seed: 7, episode_start_ms: 1700000000000, tick_ms: 1000, max_steps: 20, instruments: [{ symbol: "AAPL", prices: "100.00,101.50,103.00" }], cost: { spread_bps: spread, impact_bps: impact, lot: lot, fee_bps: 0, fee_per_unit_cents: 0 } }
}

fn buy_fill(q :: Int) -> fills.Fill {
  { step: 1, symbol: "AAPL", side: "buy", quantity: q }
}

# A 100bps spread makes a buy fill at 101.50*1.01 = 102.515; final mark 103.00
# → pnl = 100*(103-102.515) = 48.50 (vs 150.00 frictionless).
fn t_spread_cost() -> Result[Unit, Str] {
  let pnl := fills.fill_pnl(cost_scenario(100, 0, 1), buy_fill(100))
  # value 48.50 (compare by value; the decimal scale may carry extra zeros)
  if d.compare(pnl, d.decimal(485, -1)) == 0 {
    check("spread below frictionless", d.lt(pnl, fills.fill_pnl(cost_scenario(0, 0, 1), buy_fill(100))))
  } else {
    Err("expected spread pnl 48.50, got " + pos.decimal_to_str(pnl))
  }
}

# Slippage is convex in size: a 1000-share buy's per-share P&L is worse than a
# 100-share buy's. impact 10bps/100sh → small slips 10bps, big slips 100bps.
fn t_slippage_convex() -> Result[Unit, Str] {
  let sc := cost_scenario(0, 10, 100)
  let small := fills.fill_pnl(sc, buy_fill(100))
  let big := fills.fill_pnl(sc, buy_fill(1000))
  # per-share(small) > per-share(big)  <=>  small*10 > big
  check("larger order fills worse per share", d.gt(d.mul(small, d.from_int(10)), big))
}

# ---- commissions ----------------------------------------------------

fn fee_scenario(fee_bps :: Int, fee_unit :: Int) -> scenario.Scenario {
  { version: "2", name: "fee-ep", seed: 7, episode_start_ms: 1700000000000, tick_ms: 1000, max_steps: 20, instruments: [{ symbol: "AAPL", prices: "100.00,101.50,103.00" }], cost: { spread_bps: 0, impact_bps: 0, lot: 1, fee_bps: fee_bps, fee_per_unit_cents: fee_unit } }
}

# Buy 100 AAPL @ 101.50, final 103.00 → gross pnl 150.00. With 10bps + 5c/sh:
# fee = 10150*0.0010 + 100*0.05 = 10.15 + 5.00 = 15.15 → net pnl 134.85.
fn t_fee_cost() -> Result[Unit, Str] {
  let sc := fee_scenario(10, 5)
  let f := buy_fill(100)
  if d.compare(fills.fill_fee(sc, f), d.decimal(1515, -2)) == 0 {
    check("net pnl = gross - fees", d.compare(fills.fill_pnl(sc, f), d.decimal(13485, -2)) == 0)
  } else {
    Err("expected fee 15.15, got " + pos.decimal_to_str(fills.fill_fee(sc, f)))
  }
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn arena_main() -> [sql, time, crypto, fs_write] Int {
  count_failures([t_verified_roundtrip(), t_tampered_rejected(), t_scenario_id_content_addressed(), t_pnl_from_trail(), t_notional_breach_rejected(), t_spread_cost(), t_slippage_convex(), t_fee_cost()])
}

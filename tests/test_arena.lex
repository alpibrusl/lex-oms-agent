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
  { version: "2", name: "test-ep", seed: 7, episode_start_ms: 1700000000000, tick_ms: 1000, max_steps: 20, instruments: [{ symbol: "AAPL", prices: "100.00,101.50,103.00" }] }
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
  let b := { version: "2", name: "test-ep", seed: 8, episode_start_ms: 1700000000000, tick_ms: 1000, max_steps: 20, instruments: [{ symbol: "AAPL", prices: "100.00,101.50,103.00" }] }
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

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn arena_main() -> [sql, time, crypto, fs_write] Int {
  count_failures([t_verified_roundtrip(), t_tampered_rejected(), t_scenario_id_content_addressed(), t_pnl_from_trail()])
}

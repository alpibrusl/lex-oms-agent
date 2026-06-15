# lex-arena — replay verification
#
# `verify(scenario_path, trail_path)` is the arena's core mechanism:
# a submission is a trail file, not a score. We re-run the decision
# sequence extracted from the submitted trail through the identical
# sim under the scenario's clock, and the replayed trail must be
# byte-identical — every event id is a content hash, so one diverging
# fill, timestamp, or violation changes the sequence and the entry is
# rejected with the diverging position shown.
#
# The LLM's nondeterminism is irrelevant by design: what is verified is
# the accounting of the decisions actually made, not the reasoning that
# produced them.
#
# Scoring v0 (on-thesis): accepted/rejected order counts; any
# trade.order.rejected event disqualifies the episode (the perimeter
# was breached — performance doesn't count). P&L scoring arrives with
# the fill engine in the runner phase.
#
# Run:
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#     src/arena/verify.lex verify scenarios/ep1.json my_trail.jsonl
#
# Exit value: 0 = verified, 1 = rejected / error (returned as Int).

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.json" as json

import "lex-orm/src/connection" as conn

import "lex-trail/src/log" as trail_log

import "lex-oms/src/server" as srv

import "../agent" as agent

import "../tool" as tool

import "./scenario" as scenario

import "./trail_file" as tf

import "./fills" as fills

# ---- Intent payload (mirror of agent loop's enriched payload) --------
type IntentPayload = { step :: Int, tool :: Str, call :: tool.ToolCall }

type ReasonPayload = { reason :: Str }

# ---- Decision extraction ---------------------------------------------
fn extract_decisions(lines :: List[tf.Line]) -> Result[List[tool.Tool], Str] {
  let intents := list.filter(lines, fn (l :: tf.Line) -> Bool {
    l.kind == "agent.decision.intent"
  })
  list.fold(intents, Ok([]), fn (acc :: Result[List[tool.Tool], Str], l :: tf.Line) -> Result[List[tool.Tool], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(ts) => {
        let parsed :: Result[IntentPayload, Str] := json.parse(l.payload_json)
        match parsed {
          Err(e) => Err("bad intent payload: " + e),
          Ok(p) => Ok(list.concat(ts, [tool.tool_from_call(p.call)])),
        }
      },
    }
  })
}

# The goal.met reason (if the run terminated via AgentDone) — the replay
# must finish with the same reason or the goal.met hash diverges.
fn extract_done_reason(lines :: List[tf.Line]) -> Option[Str] {
  let goals := list.filter(lines, fn (l :: tf.Line) -> Bool {
    l.kind == "agent.goal.met"
  })
  match list.head(goals) {
    None => None,
    Some(l) => {
      let parsed :: Result[ReasonPayload, Str] := json.parse(l.payload_json)
      match parsed {
        Err(_) => None,
        Ok(p) => Some(p.reason),
      }
    },
  }
}

# ---- Replay -----------------------------------------------------------
fn nth_tool(decisions :: List[tool.Tool], n :: Int) -> Option[tool.Tool] {
  list.fold(list.enumerate(decisions), None, fn (acc :: Option[tool.Tool], pair :: (Int, tool.Tool)) -> Option[tool.Tool] {
    match pair {
      (i, t) => if i == n {
        Some(t)
      } else {
        acc
      },
    }
  })
}

fn replay_decide(decisions :: List[tool.Tool], done_reason :: Option[Str]) -> (List[agent.Step]) -> tool.Tool {
  fn (history :: List[agent.Step]) -> tool.Tool {
    let n := agent.steps_taken(history)
    match nth_tool(decisions, n) {
      Some(t) => t,
      None => match done_reason {
        Some(r) => AgentDone(r),
        None => AgentDone("replay: decision list exhausted"),
      },
    }
  }
}

fn dump_lines(log :: trail_log.Log) -> [sql] Result[List[tf.Line], Str] {
  match trail_log.range(log, 0, 4000000000000000) {
    Err(e) => Err(e),
    Ok(evts) => Ok(list.map(evts, fn (e :: { id :: Str, kind :: Str, parent :: Option[Str], payload_json :: Str, ts_ms :: Int }) -> tf.Line {
      let p := match e.parent {
        Some(s) => s,
        None => "",
      }
      { id: e.id, kind: e.kind, parent: p, payload_json: e.payload_json, ts_ms: e.ts_ms }
    })),
  }
}

type ReplayOut = { lines :: List[tf.Line], result :: agent.AgentResult }

fn run_replay(sc :: scenario.Scenario, decisions :: List[tool.Tool], done_reason :: Option[Str]) -> [sql, time, crypto, fs_write] Result[ReplayOut, Str] {
  match conn.connect_sqlite(":memory:") {
    Err(_) => Err("replay: db open failed"),
    Ok(db) => match srv.init_db(db) {
      Err(e) => Err("replay: init_db failed: " + e),
      Ok(_) => match scenario.seed_marks(db, sc) {
        Err(e) => Err("replay: seed_marks failed: " + e),
        Ok(_) => match trail_log.open_memory() {
          Err(e) => Err("replay: log open failed: " + e),
          Ok(log) => {
            let ctx := { db: db, log: log, max_steps: sc.max_steps, clock: scenario.clock(sc) }
            let result := agent.run(ctx, replay_decide(decisions, done_reason))
            match dump_lines(log) {
              Err(e) => Err("replay: dump failed: " + e),
              Ok(lines) => Ok({ lines: lines, result: result }),
            }
          },
        },
      },
    },
  }
}

# ---- Comparison + scoring ---------------------------------------------
fn joined_ids(lines :: List[tf.Line]) -> Str {
  str.join(list.map(lines, fn (l :: tf.Line) -> Str {
    l.id
  }), ",")
}

fn nth_id(lines :: List[tf.Line], n :: Int) -> Str {
  list.fold(list.enumerate(lines), "", fn (acc :: Str, pair :: (Int, tf.Line)) -> Str {
    match pair {
      (i, l) => if i == n {
        l.id
      } else {
        acc
      },
    }
  })
}

# First index at which the two id sequences diverge (-1 = identical).
fn first_divergence(a :: List[tf.Line], b :: List[tf.Line]) -> Int {
  let n := list.len(a)
  let m := list.len(b)
  let upto := if n < m {
    n
  } else {
    m
  }
  let hit := list.fold(list.range(0, upto), -1, fn (acc :: Int, i :: Int) -> Int {
    if acc >= 0 {
      acc
    } else {
      if nth_id(a, i) == nth_id(b, i) {
        -1
      } else {
        i
      }
    }
  })
  if hit >= 0 {
    hit
  } else {
    if n == m {
      -1
    } else {
      upto
    }
  }
}

fn count_kind(lines :: List[tf.Line], kind :: Str) -> Int {
  list.fold(lines, 0, fn (acc :: Int, l :: tf.Line) -> Int {
    if l.kind == kind {
      acc + 1
    } else {
      acc
    }
  })
}

fn result_str(r :: agent.AgentResult) -> Str {
  match r {
    GoalMet(reason) => "goal_met: " + reason,
    StepLimitReached(n) => "step_limit: " + int.to_str(n),
  }
}

fn bool_str(b :: Bool) -> Str {
  if b {
    "true"
  } else {
    "false"
  }
}

fn verdict_json(verified :: Bool, sc :: scenario.Scenario, replayed :: List[tf.Line], result :: agent.AgentResult, divergence :: Int) -> Str {
  let accepted := count_kind(replayed, "trade.order.accepted")
  let rejected := count_kind(replayed, "trade.order.rejected")
  let dq := rejected > 0
  "{\"verified\":" + bool_str(verified) + ",\"scenario\":\"" + sc.name + "\"" + ",\"scenario_id\":\"" + scenario.scenario_id(sc) + "\"" + ",\"events\":" + int.to_str(list.len(replayed)) + ",\"orders_accepted\":" + int.to_str(accepted) + ",\"orders_rejected\":" + int.to_str(rejected) + ",\"fills\":" + int.to_str(fills.fill_count(replayed)) + ",\"pnl\":\"" + fills.pnl_str(sc, replayed) + "\"" + ",\"notional\":\"" + fills.notional_str(sc, replayed) + "\"" + ",\"fees\":\"" + fills.fees_str(sc, replayed) + "\"" + ",\"disqualified\":" + bool_str(dq) + ",\"divergence_at\":" + int.to_str(divergence) + ",\"result\":\"" + result_str(result) + "\"}"
}

# ---- CLI entry ---------------------------------------------------------
fn verify(scenario_path :: Str, trail_path :: Str) -> [sql, time, crypto, fs_read, fs_write, io] Int {
  match io.read(scenario_path) {
    Err(e) => {
      let __p := io.print("{\"verified\":false,\"error\":\"cannot read scenario: " + e + "\"}")
      1
    },
    Ok(sc_json) => match scenario.from_json(sc_json) {
      Err(e) => {
        let __p := io.print("{\"verified\":false,\"error\":\"bad scenario: " + e + "\"}")
        1
      },
      Ok(sc) => match io.read(trail_path) {
        Err(e) => {
          let __p := io.print("{\"verified\":false,\"error\":\"cannot read trail: " + e + "\"}")
          1
        },
        Ok(content) => match tf.parse_jsonl(content) {
          Err(e) => {
            let __p := io.print("{\"verified\":false,\"error\":\"" + e + "\"}")
            1
          },
          Ok(submitted) => match extract_decisions(submitted) {
            Err(e) => {
              let __p := io.print("{\"verified\":false,\"error\":\"" + e + "\"}")
              1
            },
            Ok(decisions) => {
              let done_reason := extract_done_reason(submitted)
              match run_replay(sc, decisions, done_reason) {
                Err(e) => {
                  let __p := io.print("{\"verified\":false,\"error\":\"" + e + "\"}")
                  1
                },
                Ok(out) => {
                  let div := first_divergence(submitted, out.lines)
                  let verified := div == -1
                  let __p := io.print(verdict_json(verified, sc, out.lines, out.result, div))
                  if verified {
                    0
                  } else {
                    1
                  }
                },
              }
            },
          },
        },
      },
    },
  }
}


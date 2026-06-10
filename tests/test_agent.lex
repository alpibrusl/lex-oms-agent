# lex-agent — unit + integration tests
#
# Pure suite  (run_all)         : tool_name, steps_taken, submitted_symbols
# Integration (integration_main): full agent loop round-trip in memory
#   lex run --allow-effects sql,time,fs_write tests/test_agent.lex integration_main

import "std.list" as list
import "std.str" as str
import "std.int" as int
import "std.map" as map

import "lex-orm/src/connection" as conn
import "lex-trail/src/log" as trail_log

import "lex-oms/src/server" as srv

import "../src/tool" as tool
import "../src/agent" as agent

# ---- Helpers --------------------------------------------------------
fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond { Ok(()) } else { Err(name) }
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

# ---- Pure: tool_name ------------------------------------------------
fn test_tool_name_submit() -> Result[Unit, Str] {
  let t := SubmitOrder({ cl_ord_id: "T1", symbol: "AAPL", side: "buy", quantity: 100 })
  check("tool_name submit", tool.tool_name(t) == "submit_order:AAPL:buy:100")
}

fn test_tool_name_cancel() -> Result[Unit, Str] {
  let t := CancelOrder({ cl_ord_id: "C1", orig_cl_ord_id: "T1", symbol: "AAPL", side: "buy" })
  check("tool_name cancel", tool.tool_name(t) == "cancel_order:T1")
}

fn test_tool_name_observe_blotter() -> Result[Unit, Str] {
  check("tool_name observe blotter", tool.tool_name(Observe(Blotter)) == "observe:blotter")
}

fn test_tool_name_done() -> Result[Unit, Str] {
  check("tool_name done", tool.tool_name(AgentDone("goal")) == "done:goal")
}

# ---- Pure: history helpers ------------------------------------------
fn test_steps_taken_empty() -> Result[Unit, Str] {
  check("steps_taken empty", agent.steps_taken([]) == 0)
}

fn count_list(xs :: List[Str]) -> Int {
  list.fold(xs, 0, fn (acc :: Int, _x :: Str) -> Int { acc + 1 })
}

fn test_submitted_symbols_empty() -> Result[Unit, Str] {
  check("submitted_symbols empty", count_list(agent.submitted_symbols([])) == 0)
}

fn test_last_outcome_empty() -> Result[Unit, Str] {
  match agent.last_outcome([]) {
    None => Ok(()),
    Some(_) => Err("last_outcome on empty should be None"),
  }
}

# ---- Pure suite -----------------------------------------------------
fn suite_pure() -> List[Result[Unit, Str]] {
  [test_tool_name_submit(), test_tool_name_cancel(), test_tool_name_observe_blotter(), test_tool_name_done(), test_steps_taken_empty(), test_submitted_symbols_empty(), test_last_outcome_empty()]
}

fn run_all() -> Int {
  count_failures(suite_pure())
}

# ---- Integration: scripted agent runs to GoalMet --------------------
fn one_shot_decide(_history :: List[agent.Step]) -> tool.Tool {
  AgentDone("test goal met")
}

fn three_step_decide(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 { Observe(Blotter) }
  else { if n == 1 { SubmitOrder({ cl_ord_id: "IT-001", symbol: "AAPL", side: "buy", quantity: 10 }) }
  else { AgentDone("done after submit") } }
}

fn intg_one_shot_goal_met(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, crypto] Result[Unit, Str] {
  let ctx := { db: db, log: log, max_steps: 5, clock: ClockWall }
  match agent.run(ctx, one_shot_decide) {
    GoalMet(_) => Ok(()),
    StepLimitReached(n) => Err("expected GoalMet, got StepLimitReached at " + int.to_str(n)),
  }
}

fn intg_step_limit_enforced(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, crypto] Result[Unit, Str] {
  let always_observe := fn (_h :: List[agent.Step]) -> tool.Tool { Observe(Blotter) }
  let ctx := { db: db, log: log, max_steps: 3, clock: ClockWall }
  match agent.run(ctx, always_observe) {
    StepLimitReached(3) => Ok(()),
    StepLimitReached(n) => Err("expected limit at 3, got " + int.to_str(n)),
    GoalMet(_) => Err("expected StepLimitReached, got GoalMet"),
  }
}

fn intg_submit_order_accepted(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, crypto] Result[Unit, Str] {
  let ctx := { db: db, log: log, max_steps: 10, clock: ClockWall }
  let result := agent.run(ctx, three_step_decide)
  match result {
    GoalMet(_) => Ok(()),
    StepLimitReached(n) => Err("three_step_decide hit limit at " + int.to_str(n)),
  }
}

fn intg_submitted_symbols_tracked(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, crypto] Result[Unit, Str] {
  let mut_history := []
  let step0 := { step: 0, tool: SubmitOrder({ cl_ord_id: "S1", symbol: "AAPL", side: "buy", quantity: 10 }), outcome: { ok: true, status: 201, body: "{}" }, trail_id: "", call_id: "" }
  let step1 := { step: 1, tool: SubmitOrder({ cl_ord_id: "S2", symbol: "MSFT", side: "buy", quantity: 5 }), outcome: { ok: false, status: 422, body: "{}" }, trail_id: "", call_id: "" }
  let step2 := { step: 2, tool: Observe(Blotter), outcome: { ok: true, status: 200, body: "[]" }, trail_id: "", call_id: "" }
  let history := [step0, step1, step2]
  let syms := agent.submitted_symbols(history)
  check("submitted_symbols only counts ok steps", count_list(syms) == 1)
}

fn intg_audit_has_agent_events(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, crypto] Result[Unit, Str] {
  let ctx := { db: db, log: log, max_steps: 5, clock: ClockWall }
  let __r := agent.run(ctx, one_shot_decide)
  let audit_resp := srv.get_audit(log, { method: "GET", path: "/audit", query: "", body: "", path_params: map.new(), headers: map.new(), state: map.new() })
  check("audit contains agent.goal.met", str.contains(audit_resp.body, "agent.goal.met"))
}

# ---- Sim-clock determinism ------------------------------------------
# Run the same observe-only script in two fresh (db, log) pairs under
# ClockSim; the full trail id sequences must be byte-identical. Scope:
# observe-only because SubmitOrder triggers OMS-side trail writes that
# still use wall-clock append (lex-oms conversion is the next change).
fn observe_then_done(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n >= 2 { AgentDone("observed") } else { Observe(Blotter) }
}

fn joined_trail_ids() -> [sql, time, crypto, fs_write] Result[Str, Str] {
  match conn.connect_sqlite(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __init := srv.init_db(db)
      match trail_log.open_memory() {
        Err(_) => Err("log open failed"),
        Ok(log) => {
          let ctx := { db: db, log: log, max_steps: 5, clock: ClockSim(1700000000000, 1000) }
          let __r := agent.run(ctx, observe_then_done)
          match trail_log.range(log, 0, 4000000000000000) {
            Err(e) => Err(e),
            Ok(evts) => Ok(list.fold(evts, "", fn (acc :: Str, e :: { id :: Str, kind :: Str, parent :: Option[Str], payload_json :: Str, ts_ms :: Int }) -> Str { acc + e.id + "," })),
          }
        },
      }
    },
  }
}

fn intg_sim_clock_deterministic() -> [sql, time, crypto, fs_write] Result[Unit, Str] {
  match joined_trail_ids() {
    Err(e) => Err("run 1: " + e),
    Ok(ids1) => match joined_trail_ids() {
      Err(e) => Err("run 2: " + e),
      Ok(ids2) => if str.is_empty(ids1) {
        Err("sim run produced no trail events")
      } else {
        check("sim-clock trails byte-identical across runs", ids1 == ids2)
      },
    },
  }
}

fn suite_integration(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, crypto, fs_write] List[Result[Unit, Str]] {
  let __init := srv.init_db(db)
  [intg_one_shot_goal_met(db, log), intg_step_limit_enforced(db, log), intg_submit_order_accepted(db, log), intg_submitted_symbols_tracked(db, log), intg_audit_has_agent_events(db, log), intg_sim_clock_deterministic()]
}

fn integration_main() -> [sql, time, crypto, fs_write] Int {
  match conn.connect_sqlite(":memory:") {
    Err(_) => 1,
    Ok(db) => match trail_log.open_memory() {
      Err(_) => 1,
      Ok(log) => count_failures(suite_integration(db, log)),
    },
  }
}

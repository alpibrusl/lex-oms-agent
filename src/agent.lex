# lex-agent — typed agent loop
#
# The agent loop is parameterised over a decision function so the same
# machinery works with:
#   - a scripted sequence (tests, demos)
#   - a real LLM via lex-llm or a direct Anthropic HTTP call
#   - a rule-based engine
#
# Audit ordering per step:
#   1. agent.decision.intent  — logged BEFORE dispatch (proves what was decided)
#      → if this write fails, dispatch is skipped and the loop halts
#   2. tool.dispatch()        — OMS call; lex-trail records trade events here
#   3. agent.decision.made    — logged AFTER dispatch with outcome; parent = intent id
#      → if this write fails, the loop halts (audit contract broken)
#
# Trail failures on terminal events (goal.met, budget.exhausted) are noted but
# do not suppress the result — the agent has already finished acting.
#
# Effects: [sql, time, crypto]

import "std.list" as list
import "std.str" as str
import "std.int" as int

import "lex-orm/src/connection" as conn
import "lex-trail/src/log" as trail_log

import "./trail_kinds" as kinds
import "./tool" as tool

# ---- Types ----------------------------------------------------------

# One completed step in the agent's history.
type Step = {
  step     :: Int,
  tool     :: tool.Tool,
  outcome  :: tool.ToolOutcome,
  trail_id :: Str,
  call_id  :: Str,   # LLM-assigned call_id (may include "|||thoughtSignature"); "" for scripted steps
}

# Terminal outcome of a run.
type AgentResult = GoalMet(Str) | StepLimitReached(Int)

# Immutable context passed through every step.
type AgentCtx = {
  db        :: conn.ConnDb,
  log       :: trail_log.Log,
  max_steps :: Int,
}

# ---- Public API -----------------------------------------------------

# Run the agent loop until Done or max_steps reached.
# decide(history) returns the next Tool to execute (pure / scripted).
fn run(ctx :: AgentCtx, decide :: (List[Step]) -> tool.Tool) -> [sql, time, crypto] AgentResult {
  step_loop(ctx, decide, [], 0)
}

# LLM-backed variant: decide returns (tool, call_id) so thoughtSignatures survive history reconstruction.
fn run_with_llm(ctx :: AgentCtx, decide :: (List[Step]) -> [net, llm] (tool.Tool, Str)) -> [sql, time, crypto, net, llm] AgentResult {
  step_loop_llm(ctx, decide, [], 0)
}

# LLM-backed variant that also returns the full step history (for fill simulation etc).
fn run_with_llm_history(ctx :: AgentCtx, decide :: (List[Step]) -> [net, llm] (tool.Tool, Str)) -> [sql, time, crypto, net, llm] (AgentResult, List[Step]) {
  step_loop_llm_history(ctx, decide, [], 0)
}

# ---- Internal loop --------------------------------------------------

fn step_loop(ctx :: AgentCtx, decide :: (List[Step]) -> tool.Tool, history :: List[Step], n :: Int) -> [sql, time, crypto] AgentResult {
  if n >= ctx.max_steps {
    let _trail := trail_log.append(ctx.log, kinds.budget_exhausted(), None, "{\"steps_taken\":" + int.to_str(n) + "}")
    StepLimitReached(n)
  } else {
    let t := decide(history)
    match t {
      AgentDone(reason) => {
        let _trail := trail_log.append(ctx.log, kinds.goal_met(), None, "{\"reason\":\"" + tool.escape_json_str(reason) + "\"}")
        GoalMet(reason)
      },
      _ => {
        let intent_payload := "{\"step\":" + int.to_str(n) + ",\"tool\":\"" + tool.tool_name(t) + "\"}"
        match trail_log.append(ctx.log, kinds.decision_intent(), None, intent_payload) {
          Err(_) => StepLimitReached(n),
          Ok(intent_evt) => {
            let outcome := tool.dispatch(ctx.db, ctx.log, t)
            let payload := make_payload(n, t, outcome)
            match trail_log.append(ctx.log, kinds.decision_made(), Some(intent_evt.id), payload) {
              Err(_) => StepLimitReached(n),
              Ok(out_evt) => {
                let entry := { step: n, tool: t, outcome: outcome, trail_id: out_evt.id, call_id: "" }
                step_loop(ctx, decide, list.concat(history, [entry]), n + 1)
              },
            }
          },
        }
      },
    }
  }
}

fn step_loop_llm(ctx :: AgentCtx, decide :: (List[Step]) -> [net, llm] (tool.Tool, Str), history :: List[Step], n :: Int) -> [sql, time, crypto, net, llm] AgentResult {
  if n >= ctx.max_steps {
    let _trail := trail_log.append(ctx.log, kinds.budget_exhausted(), None, "{\"steps_taken\":" + int.to_str(n) + "}")
    StepLimitReached(n)
  } else {
    let tc  := decide(history)
    let t   := match tc { (x, _) => x }
    let cid := match tc { (_, c) => c }
    match t {
      AgentDone(reason) => {
        let _trail := trail_log.append(ctx.log, kinds.goal_met(), None, "{\"reason\":\"" + tool.escape_json_str(reason) + "\"}")
        GoalMet(reason)
      },
      _ => {
        let intent_payload := "{\"step\":" + int.to_str(n) + ",\"tool\":\"" + tool.tool_name(t) + "\"}"
        match trail_log.append(ctx.log, kinds.decision_intent(), None, intent_payload) {
          Err(_) => StepLimitReached(n),
          Ok(intent_evt) => {
            let outcome := tool.dispatch(ctx.db, ctx.log, t)
            let payload := make_payload(n, t, outcome)
            match trail_log.append(ctx.log, kinds.decision_made(), Some(intent_evt.id), payload) {
              Err(_) => StepLimitReached(n),
              Ok(out_evt) => {
                let entry := { step: n, tool: t, outcome: outcome, trail_id: out_evt.id, call_id: cid }
                step_loop_llm(ctx, decide, list.concat(history, [entry]), n + 1)
              },
            }
          },
        }
      },
    }
  }
}

fn step_loop_llm_history(ctx :: AgentCtx, decide :: (List[Step]) -> [net, llm] (tool.Tool, Str), history :: List[Step], n :: Int) -> [sql, time, crypto, net, llm] (AgentResult, List[Step]) {
  if n >= ctx.max_steps {
    let _trail := trail_log.append(ctx.log, kinds.budget_exhausted(), None, "{\"steps_taken\":" + int.to_str(n) + "}")
    (StepLimitReached(n), history)
  } else {
    let tc  := decide(history)
    let t   := match tc { (x, _) => x }
    let cid := match tc { (_, c) => c }
    match t {
      AgentDone(reason) => {
        let _trail := trail_log.append(ctx.log, kinds.goal_met(), None, "{\"reason\":\"" + tool.escape_json_str(reason) + "\"}")
        (GoalMet(reason), history)
      },
      _ => {
        let intent_payload := "{\"step\":" + int.to_str(n) + ",\"tool\":\"" + tool.tool_name(t) + "\"}"
        match trail_log.append(ctx.log, kinds.decision_intent(), None, intent_payload) {
          Err(_) => (StepLimitReached(n), history),
          Ok(intent_evt) => {
            let outcome := tool.dispatch(ctx.db, ctx.log, t)
            let payload := make_payload(n, t, outcome)
            match trail_log.append(ctx.log, kinds.decision_made(), Some(intent_evt.id), payload) {
              Err(_) => (StepLimitReached(n), history),
              Ok(out_evt) => {
                let entry := { step: n, tool: t, outcome: outcome, trail_id: out_evt.id, call_id: cid }
                step_loop_llm_history(ctx, decide, list.concat(history, [entry]), n + 1)
              },
            }
          },
        }
      },
    }
  }
}

fn make_payload(n :: Int, t :: tool.Tool, outcome :: tool.ToolOutcome) -> Str {
  "{\"step\":" + int.to_str(n) + ",\"tool\":\"" + tool.tool_name(t) + "\",\"ok\":" + bool_s(outcome.ok) + ",\"status\":" + int.to_str(outcome.status) + "}"
}

fn bool_s(b :: Bool) -> Str {
  if b { "true" } else { "false" }
}

# ---- History helpers (for decision functions to query) --------------

fn last_outcome(history :: List[Step]) -> Option[tool.ToolOutcome] {
  match list.head(list.reverse(history)) {
    None => None,
    Some(s) => Some(s.outcome),
  }
}

fn steps_taken(history :: List[Step]) -> Int {
  list.fold(history, 0, fn (acc :: Int, _s :: Step) -> Int { acc + 1 })
}

fn submitted_symbols(history :: List[Step]) -> List[Str] {
  list.fold(history, [], fn (acc :: List[Str], s :: Step) -> List[Str] {
    match s.tool {
      SubmitOrder(p) => if s.outcome.ok { list.concat(acc, [p.symbol]) } else { acc },
      _ => acc,
    }
  })
}

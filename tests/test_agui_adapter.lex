# lex-oms-agent — agui_adapter.lex tests (pure, run via `lex test`)

import "std.list" as list

import "lex-ag-ui/src/event" as ev

import "../src/agui_adapter" as adapter

import "../src/tool" as tool

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn encoded(events :: List[ev.AguiEvent]) -> List[Str] {
  list.map(events, ev.encode)
}

fn test_from_history_one_step_goal_met() -> Result[Unit, Str] {
  let step := { step: 1, tool: Observe(Blotter), outcome: { ok: true, status: 200, body: "[]" }, trail_id: "trail_1", call_id: "call_1" }
  let got := adapter.from_history(GoalMet("done"), [step], "t1", "r1")
  let want := [RunStarted({ thread_id: "t1", run_id: "r1" }), ToolCallStart({ tool_call_id: "call_1", tool_call_name: tool.tool_name(Observe(Blotter)), parent_message_id: None }), ToolCallArgs({ tool_call_id: "call_1", delta: tool.tool_json(Observe(Blotter)) }), ToolCallEnd({ tool_call_id: "call_1" }), ToolCallResult({ message_id: "trail_1", tool_call_id: "call_1", content: "[]" }), TextMessageStart({ message_id: "final", role: "assistant" }), TextMessageContent({ message_id: "final", delta: "Goal met: done" }), TextMessageEnd({ message_id: "final" }), RunFinished({ thread_id: "t1", run_id: "r1" })]
  check("from_history: one step, GoalMet -> full RUN_STARTED..TOOL_CALL_*..RUN_FINISHED sequence", encoded(got) == encoded(want))
}

fn test_from_history_no_steps_step_limit() -> Result[Unit, Str] {
  let got := adapter.from_history(StepLimitReached(20), [], "t1", "r1")
  let want := [RunStarted({ thread_id: "t1", run_id: "r1" }), TextMessageStart({ message_id: "final", role: "assistant" }), TextMessageContent({ message_id: "final", delta: "Step limit reached after 20 steps" }), TextMessageEnd({ message_id: "final" }), RunFinished({ thread_id: "t1", run_id: "r1" })]
  check("from_history: zero steps, StepLimitReached -> no TOOL_CALL_* events, correct summary text", encoded(got) == encoded(want))
}

fn suite_pure() -> List[Result[Unit, Str]] {
  [test_from_history_one_step_goal_met(), test_from_history_no_steps_step_limit()]
}

# lex test discards run_all's return value and only checks whether the
# call raises a runtime error -- see tests/test_agent.lex's comment.
fn run_all() -> Int {
  let failures := count_failures(suite_pure())
  let _crash_if_failed := if failures > 0 {
    1 / 0
  } else {
    0
  }
  failures
}


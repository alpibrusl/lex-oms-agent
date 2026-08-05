# lex-oms-agent — adapt the agent's own Step/AgentResult history into
# AG-UI events (lex-ag-ui).
#
# This agent's decision loop (`agent.run_with_llm_history`) is NOT built
# on `lex-llm/src/agent.lex`'s `run_loop` -- it has its own tool-call
# history type (`agent.Step = { step, tool, outcome, trail_id, call_id }`),
# a completed-decision record, not a token-level delta stream
# (`llm_decide.make_decide` collects each LLM call's full response
# before returning). So this can't use `lex-ag-ui/src/bridge.lex`
# (which is specifically shaped for `lex-llm`'s `Iter[Step]`) --
# instead it's a small, direct adapter to `lex-ag-ui`'s `AguiEvent`,
# mounted via the generic `mount.add_to_events` (see
# lex-ag-ui/src/mount.lex's module doc for exactly this case).
#
# What a caller gets: one TOOL_CALL_START/ARGS/END/RESULT quad per
# completed step (tool name, JSON args, and the OMS's response body as
# the result content -- all real data, not placeholders, unlike
# lex-ag-ui's own lex-llm bridge which only has a success/failure flag
# for tool results), then a closing text message with the run's outcome.
#
# Same caveat as lex-ag-ui's own bridge: not token-level streaming --
# `run_with_llm_history` runs the whole multi-step loop to completion
# before this ever sees a Step, so a caller watching this endpoint sees
# the full history arrive at once, over a real SSE connection, once the
# goal is met or the step limit is hit. True incremental streaming would
# need `make_decide`/`run_with_llm` restructured to expose each
# provider.chat call's own delta stream -- a real change to this agent's
# core loop, out of scope here.
#
# Effects: none. Construction is pure.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "lex-ag-ui/src/event" as ev

import "./agent" as agent

import "./tool" as tool

fn step_events(s :: agent.Step) -> List[ev.AguiEvent] {
  [ev.ToolCallStart({ tool_call_id: s.call_id, tool_call_name: tool.tool_name(s.tool), parent_message_id: None }), ev.ToolCallArgs({ tool_call_id: s.call_id, delta: tool.tool_json(s.tool) }), ev.ToolCallEnd({ tool_call_id: s.call_id }), ev.ToolCallResult({ message_id: s.trail_id, tool_call_id: s.call_id, content: s.outcome.body })]
}

fn result_text(r :: agent.AgentResult) -> Str {
  match r {
    GoalMet(summary) => str.concat("Goal met: ", summary),
    StepLimitReached(n) => str.concat("Step limit reached after ", str.concat(int.to_str(n), " steps")),
  }
}

fn result_events(r :: agent.AgentResult, message_id :: Str) -> List[ev.AguiEvent] {
  let text := result_text(r)
  [ev.TextMessageStart({ message_id: message_id, role: "assistant" }), ev.TextMessageContent({ message_id: message_id, delta: text }), ev.TextMessageEnd({ message_id: message_id })]
}

# Public entry point: turn a completed run's (AgentResult, List[Step])
# -- exactly what `agent.run_with_llm_history` returns -- into the full
# AG-UI event list for that run.
fn from_history(result :: agent.AgentResult, steps :: List[agent.Step], thread_id :: Str, run_id :: Str) -> List[ev.AguiEvent] {
  let step_event_lists := list.map(steps, step_events)
  let flat_step_events := list.fold(step_event_lists, [], fn (acc :: List[ev.AguiEvent], evs :: List[ev.AguiEvent]) -> List[ev.AguiEvent] {
    list.concat(acc, evs)
  })
  let closing := result_events(result, "final")
  list.concat([ev.RunStarted({ thread_id: thread_id, run_id: run_id })], list.concat(flat_step_events, list.concat(closing, [ev.RunFinished({ thread_id: thread_id, run_id: run_id })])))
}


# lex-agent — LLM-backed decide function
#
# make_decide(provider, model) returns a decide function compatible with
# agent.run_with_llm. Each call to decide:
#   1. Converts the history into a Messages conversation.
#   2. Calls provider.chat once (single LLM turn).
#   3. Collects Deltas and extracts the first tool call.
#   4. Maps the tool call to a tool.Tool variant.
#
# The LLM is prompted with four tools:
#   submit_order, cancel_order, observe, done
#
# Effects: [net, llm] (via provider.chat)

import "lex-llm/message" as msg

import "lex-llm/delta" as d

import "lex-llm/tool" as lt

import "lex-llm/provider" as prov

import "lex-schema/schema" as s

import "lex-schema/json_value" as jv

import "lex-schema/error" as e

import "lex-schema/constraints" as c

import "std.list" as list

import "std.str" as str

import "std.iter" as iter

import "std.int" as int

import "./tool" as tool

import "./agent" as agent

# ---- System prompt -------------------------------------------------
fn system_prompt(goal :: Str) -> Str {
  str.join(["You are a trading agent connected to an Order Management System (OMS).\n", "GOAL: ", goal, "\n\n", "RULES — follow these exactly:\n", "1. You MUST respond with a tool call every single turn. Never respond with text only.\n", "2. Call exactly one tool per turn.\n", "3. Available tools: observe (target: blotter/positions/risk/audit), submit_order, cancel_order, done.\n", "4. After observing, immediately proceed to submit orders toward the goal.\n", "5. An order with state PendingNew means it has been accepted by the OMS. That counts as accepted — do NOT wait for Filled state. When all required orders are PendingNew or Filled, call done with a summary.\n\n", "Do not explain your reasoning in text. Just call the next tool."], "")
}

# ---- Tool schemas (lex-llm t.Tool descriptors) ---------------------
fn make_submit_tool() -> lt.Tool {
  let params := { title: "SubmitOrderArgs", description: "Place a new market order.", fields: [s.required_str("cl_ord_id", [c.StrNonEmpty]), s.required_str("symbol", [c.StrNonEmpty]), s.required_str("side", [c.StrOneOf(["buy", "sell"])]), s.required_int("quantity", [])] }
  lt.define("submit_order", "Submit a market order to the OMS.", params, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(JObj([]))
  })
}

fn make_cancel_tool() -> lt.Tool {
  let params := { title: "CancelOrderArgs", description: "Cancel an existing order.", fields: [s.required_str("cl_ord_id", [c.StrNonEmpty]), s.required_str("orig_cl_ord_id", [c.StrNonEmpty]), s.required_str("symbol", [c.StrNonEmpty]), s.required_str("side", [c.StrOneOf(["buy", "sell"])])] }
  lt.define("cancel_order", "Cancel an existing OMS order by its cl_ord_id.", params, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(JObj([]))
  })
}

fn make_observe_tool() -> lt.Tool {
  let params := { title: "ObserveArgs", description: "Read current OMS state.", fields: [s.required_str("target", [c.StrOneOf(["blotter", "positions", "risk", "audit"])])] }
  lt.define("observe", "Observe the OMS state: blotter, positions, risk, or audit.", params, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(JObj([]))
  })
}

fn make_done_tool() -> lt.Tool {
  let params := { title: "DoneArgs", description: "Signal that the goal is met.", fields: [s.required_str("reason", [c.StrNonEmpty])] }
  lt.define("done", "Signal that the trading goal is fully achieved.", params, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(JObj([]))
  })
}

fn all_tools() -> List[lt.Tool] {
  [make_observe_tool(), make_submit_tool(), make_cancel_tool(), make_done_tool()]
}

# ---- History → Messages conversion ---------------------------------
fn step_to_messages(step :: agent.Step) -> List[msg.Message] {
  let call_id := if str.is_empty(step.call_id) {
    str.concat("call_", tool_call_name(step.tool))
  } else {
    step.call_id
  }
  let args_json := tool_args_json(step.tool)
  let assistant := AssistantMsg("", [{ id: call_id, name: tool_call_name(step.tool), args: args_json }])
  let result_body := if step.outcome.ok {
    str.concat("{\"result\":", str.concat(step.outcome.body, "}"))
  } else {
    str.concat("{\"error\":\"status ", str.concat(int.to_str(step.outcome.status), str.concat("\",\"body\":", str.concat(step.outcome.body, "}"))))
  }
  let tool_msg := ToolMsg(call_id, result_body)
  [assistant, tool_msg]
}

fn tool_call_name(t :: tool.Tool) -> Str {
  match t {
    SubmitOrder(_) => "submit_order",
    CancelOrder(_) => "cancel_order",
    Observe(_) => "observe",
    AgentDone(_) => "done",
  }
}

fn tool_args_json(t :: tool.Tool) -> jv.Json {
  match t {
    SubmitOrder(p) => JObj([("cl_ord_id", JStr(p.cl_ord_id)), ("symbol", JStr(p.symbol)), ("side", JStr(p.side)), ("quantity", JInt(p.quantity))]),
    CancelOrder(p) => JObj([("cl_ord_id", JStr(p.cl_ord_id)), ("orig_cl_ord_id", JStr(p.orig_cl_ord_id)), ("symbol", JStr(p.symbol)), ("side", JStr(p.side))]),
    Observe(tgt) => JObj([("target", JStr(observe_target_str(tgt)))]),
    AgentDone(reason) => JObj([("reason", JStr(reason))]),
  }
}

fn observe_target_str(tgt :: tool.ObserveTarget) -> Str {
  match tgt {
    Blotter => "blotter",
    Positions => "positions",
    Risk => "risk",
    Audit => "audit",
  }
}

fn history_to_messages(history :: List[agent.Step]) -> List[msg.Message] {
  list.fold(history, [], fn (acc :: List[msg.Message], step :: agent.Step) -> List[msg.Message] {
    list.concat(acc, step_to_messages(step))
  })
}

# ---- Delta collection & tool-call extraction ----------------------
type CollectedCall = { id :: Str, name :: Str, args_raw :: Str }

type CollectedResponse = { content :: Str, calls :: List[CollectedCall], finish_reason :: Str }

fn collect_deltas(deltas :: List[d.Delta]) -> CollectedResponse {
  list.fold(deltas, { content: "", calls: [], finish_reason: "stop" }, fn (acc :: CollectedResponse, dl :: d.Delta) -> CollectedResponse {
    match dl {
      TextChunk(s) => { content: str.concat(acc.content, s), calls: acc.calls, finish_reason: acc.finish_reason },
      ToolCallBegin(id, name) => { content: acc.content, calls: list.concat(acc.calls, [{ id: id, name: name, args_raw: "" }]), finish_reason: acc.finish_reason },
      ToolArgChunk(id, chunk) => { content: acc.content, calls: append_chunk(acc.calls, id, chunk), finish_reason: acc.finish_reason },
      FinishDelta(reason) => {
        let actual := if reason == "stop" {
          if list.is_empty(acc.calls) {
            "stop"
          } else {
            "tool_calls"
          }
        } else {
          reason
        }
        { content: acc.content, calls: list.reverse(acc.calls), finish_reason: actual }
      },
    }
  })
}

fn append_chunk(calls :: List[CollectedCall], id :: Str, chunk :: Str) -> List[CollectedCall] {
  list.map(calls, fn (c :: CollectedCall) -> CollectedCall {
    if c.id == id {
      { id: c.id, name: c.name, args_raw: str.concat(c.args_raw, chunk) }
    } else {
      c
    }
  })
}

# ---- Map LLM tool call → tool.Tool --------------------------------
fn parse_tool(call :: CollectedCall) -> tool.Tool {
  let args := match jv.parse_into_errors(call.args_raw) {
    Ok(j) => j,
    Err(_) => JObj([]),
  }
  match call.name {
    "submit_order" => {
      let cl_ord_id := str_field(args, "cl_ord_id")
      let symbol := str_field(args, "symbol")
      let side := str_field(args, "side")
      let quantity := int_field(args, "quantity")
      SubmitOrder({ cl_ord_id: cl_ord_id, symbol: symbol, side: side, quantity: quantity })
    },
    "cancel_order" => {
      let cl_ord_id := str_field(args, "cl_ord_id")
      let orig_cl_ord_id := str_field(args, "orig_cl_ord_id")
      let symbol := str_field(args, "symbol")
      let side := str_field(args, "side")
      CancelOrder({ cl_ord_id: cl_ord_id, orig_cl_ord_id: orig_cl_ord_id, symbol: symbol, side: side })
    },
    "observe" => {
      let target := str_field(args, "target")
      Observe(parse_observe_target(target))
    },
    _ => AgentDone(str_field(args, "reason")),
  }
}

fn parse_observe_target(s :: Str) -> tool.ObserveTarget {
  match s {
    "blotter" => Blotter,
    "positions" => Positions,
    "risk" => Risk,
    "audit" => Audit,
    _ => Blotter,
  }
}

fn str_field(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn int_field(j :: jv.Json, key :: Str) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(n)) => n,
    _ => 0,
  }
}

# ---- Public API ---------------------------------------------------
# make_decide returns a decide function for agent.run_with_llm.
# Returns (tool, call_id) so the call_id (including any thoughtSignature) is
# preserved in Step.call_id and correctly replayed in history reconstruction.
fn make_decide(provider :: prov.Provider, model :: prov.ModelRef, goal :: Str) -> (List[agent.Step]) -> [net, llm] (tool.Tool, Str) {
  fn (history :: List[agent.Step]) -> [net, llm] (tool.Tool, Str) {
    let sys := SystemMsg(system_prompt(goal))
    let init := UserMsg("Begin. Call observe with target=positions now.")
    let hist_msgs := history_to_messages(history)
    let messages := list.concat([sys, init], hist_msgs)
    let raw_deltas := iter.to_list(provider.chat(model, messages, all_tools()))
    let resp := collect_deltas(raw_deltas)
    match list.head(resp.calls) {
      Some(call) => (parse_tool(call), call.id),
      None => (AgentDone(if str.is_empty(resp.content) {
        "no tool call returned"
      } else {
        resp.content
      }), ""),
    }
  }
}


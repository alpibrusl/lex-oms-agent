# lex-agent — Anthropic Messages API provider (fixed)
#
# The upstream lex-llm adapter omits auth headers (uses http.post).
# This adapter uses http.stream_lines so x-api-key and anthropic-version
# are sent on every request.
#
# Effects: [net, llm]

import "lex-llm/message"  as msg
import "lex-llm/delta"    as d
import "lex-llm/tool"     as t
import "lex-llm/provider" as prov

import "lex-schema/json_value" as jv

import "std.http"  as http
import "std.list"  as list
import "std.str"   as str
import "std.map"   as map
import "std.iter"  as iter

type AnthropicConfig = { api_key :: Str, base_url :: Str }

fn default_config(api_key :: Str) -> AnthropicConfig {
  { api_key: api_key, base_url: "https://api.anthropic.com/v1/messages" }
}

fn make_provider(config :: AnthropicConfig) -> prov.Provider {
  { name: "anthropic",
    chat: fn (model :: prov.ModelRef, messages :: List[msg.Message], tools :: List[t.Tool]) -> [net, llm] Iter[d.Delta] {
      chat(config, model, messages, tools)
    }
  }
}

fn build_headers(api_key :: Str) -> Map[Str, Str] {
  map.from_list([
    ("x-api-key", api_key),
    ("anthropic-version", "2023-06-01"),
    ("content-type", "application/json"),
    ("accept", "text/event-stream"),
  ])
}

fn chat(config :: AnthropicConfig, model :: prov.ModelRef, messages :: List[msg.Message], tools :: List[t.Tool]) -> [net, llm] Iter[d.Delta] {
  let body := build_request(model, messages, tools)
  let headers := build_headers(config.api_key)
  let lines := match http.stream_lines(config.base_url, headers, body) {
    Err(_) => [],
    Ok(it)  => iter.to_list(it),
  }
  parse_stream(lines)
}

# ---- Request building -----------------------------------------------

fn build_request(model :: prov.ModelRef, messages :: List[msg.Message], tools :: List[t.Tool]) -> Str {
  let sys := extract_system(messages)
  let user_msgs := filter_non_system(messages)
  let base := [("model", JStr(model.model)), ("max_tokens", JInt(4096)), ("stream", JBool(true)), ("messages", JList(list.map(user_msgs, encode_message)))]
  let with_sys := if str.is_empty(sys) { base } else { list.concat(base, [("system", JStr(sys))]) }
  let with_tools := if list.is_empty(tools) { with_sys } else { list.concat(with_sys, [("tools", JList(list.map(tools, t.to_anthropic_json)))]) }
  jv.stringify(JObj(with_tools))
}

fn extract_system(messages :: List[msg.Message]) -> Str {
  list.fold(messages, "", fn (acc :: Str, m :: msg.Message) -> Str {
    match m { SystemMsg(s) => s, _ => acc }
  })
}

fn filter_non_system(messages :: List[msg.Message]) -> List[msg.Message] {
  list.fold(messages, [], fn (acc :: List[msg.Message], m :: msg.Message) -> List[msg.Message] {
    match m { SystemMsg(_) => acc, _ => list.concat(acc, [m]) }
  })
}

fn encode_message(m :: msg.Message) -> jv.Json {
  match m {
    UserMsg(text) => JObj([("role", JStr("user")), ("content", JStr(text))]),
    AssistantMsg(text, calls) => if list.is_empty(calls) {
      JObj([("role", JStr("assistant")), ("content", JStr(text))])
    } else {
      JObj([("role", JStr("assistant")), ("content", JList(list.map(calls, encode_tool_use_block)))])
    },
    ToolMsg(call_id, content) => JObj([("role", JStr("user")), ("content", JList([JObj([("type", JStr("tool_result")), ("tool_use_id", JStr(call_id)), ("content", JStr(content))])]))]),
    SystemMsg(_) => JObj([("role", JStr("user")), ("content", JStr(""))]),
  }
}

fn encode_tool_use_block(call :: msg.ToolCall) -> jv.Json {
  JObj([("type", JStr("tool_use")), ("id", JStr(call.id)), ("name", JStr(call.name)), ("input", call.args)])
}

# ---- SSE parsing ---------------------------------------------------

type ParseState = { block_type :: Str, tool_id :: Str, tool_name :: Str }

fn parse_stream(lines :: List[Str]) -> Iter[d.Delta] {
  let init := { block_type: "", tool_id: "", tool_name: "" }
  let result := list.fold(lines, (init, []), fn (acc :: (ParseState, List[d.Delta]), line :: Str) -> (ParseState, List[d.Delta]) {
    let state := match acc { (s, _) => s }
    let so_far := match acc { (_, ds) => ds }
    let trimmed := str.trim(line)
    if str.starts_with(trimmed, "data: ") {
      let payload := str.slice(trimmed, 6, str.len(trimmed))
      if payload == "[DONE]" { acc } else {
        match jv.parse_into_errors(payload) {
          Err(_) => acc,
          Ok(j) => {
            let handled := handle_event(state, j)
            let new_state := match handled { (s, _) => s }
            let new_deltas := match handled { (_, ds) => ds }
            (new_state, list.concat(so_far, new_deltas))
          },
        }
      }
    } else { acc }
  })
  iter.from_list(match result { (_, ds) => ds })
}

fn handle_event(state :: ParseState, j :: jv.Json) -> (ParseState, List[d.Delta]) {
  match jv.get_field(j, "type") {
    Some(JStr(t)) => match t {
      "content_block_start" => handle_block_start(state, j),
      "content_block_delta" => handle_block_delta(state, j),
      "message_delta"       => handle_message_delta(state, j),
      _ => (state, []),
    },
    _ => (state, []),
  }
}

fn handle_block_start(state :: ParseState, j :: jv.Json) -> (ParseState, List[d.Delta]) {
  match jv.get_field(j, "content_block") {
    None => (state, []),
    Some(block) => match jv.get_field(block, "type") {
      Some(JStr("tool_use")) => {
        let id   := str_field(block, "id")
        let name := str_field(block, "name")
        ({ block_type: "tool_use", tool_id: id, tool_name: name }, [ToolCallBegin(id, name)])
      },
      Some(JStr("text")) => ({ block_type: "text", tool_id: state.tool_id, tool_name: state.tool_name }, []),
      _ => (state, []),
    },
  }
}

fn handle_block_delta(state :: ParseState, j :: jv.Json) -> (ParseState, List[d.Delta]) {
  match jv.get_field(j, "delta") {
    None => (state, []),
    Some(delta) => match jv.get_field(delta, "type") {
      Some(JStr("text_delta")) => {
        let text := str_field(delta, "text")
        if str.is_empty(text) { (state, []) } else { (state, [TextChunk(text)]) }
      },
      Some(JStr("input_json_delta")) => {
        let chunk := str_field(delta, "partial_json")
        if str.is_empty(chunk) { (state, []) } else { (state, [ToolArgChunk(state.tool_id, chunk)]) }
      },
      _ => (state, []),
    },
  }
}

fn handle_message_delta(state :: ParseState, j :: jv.Json) -> (ParseState, List[d.Delta]) {
  match jv.get_field(j, "delta") {
    None => (state, []),
    Some(delta) => match jv.get_field(delta, "stop_reason") {
      Some(JStr(reason)) => (state, [FinishDelta(normalise_stop(reason))]),
      _ => (state, []),
    },
  }
}

fn normalise_stop(reason :: Str) -> Str {
  match reason {
    "end_turn"  => "stop",
    "tool_use"  => "tool_calls",
    "max_tokens" => "length",
    other => other,
  }
}

fn str_field(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) { Some(JStr(s)) => s, _ => "" }
}

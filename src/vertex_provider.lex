# lex-agent — Google Vertex AI provider (Gemini 3.5)
#
# Uses the Vertex AI streamGenerateContent endpoint.
# Auth: Bearer token (service account / ADC) via VERTEX_TOKEN env var,
#       or API key via VERTEX_API_KEY env var (appended as ?key=… query param).
#
# Endpoint:
#   https://{region}-aiplatform.googleapis.com/v1/projects/{project}/
#   locations/{region}/publishers/google/models/{model}:streamGenerateContent
#
# Request/response format is identical to the public Gemini API
# (NDJSON-streamed candidates). The google.lex parser is reused.
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

# ---- Config ---------------------------------------------------------

type VertexConfig = {
  project   :: Str,
  region    :: Str,
  auth_mode :: VertexAuth,
}

type VertexAuth = BearerToken(Str) | ApiKey(Str)

fn bearer_config(project :: Str, region :: Str, token :: Str) -> VertexConfig {
  { project: project, region: region, auth_mode: BearerToken(token) }
}

fn api_key_config(project :: Str, region :: Str, key :: Str) -> VertexConfig {
  { project: project, region: region, auth_mode: ApiKey(key) }
}

fn vertex_url(cfg :: VertexConfig, model :: Str) -> Str {
  let base := str.join([
    "https://", cfg.region, "-aiplatform.googleapis.com/v1/projects/",
    cfg.project, "/locations/", cfg.region,
    "/publishers/google/models/", model, ":streamGenerateContent",
  ], "")
  match cfg.auth_mode {
    ApiKey(k)     => str.concat(base, str.concat("?key=", k)),
    BearerToken(_) => base,
  }
}

fn build_headers(cfg :: VertexConfig) -> Map[Str, Str] {
  let base_hdrs := [("content-type", "application/json"), ("accept", "application/json")]
  match cfg.auth_mode {
    BearerToken(tok) => map.from_list(list.concat(base_hdrs, [("authorization", str.concat("Bearer ", tok))])),
    ApiKey(_)        => map.from_list(base_hdrs),
  }
}

# ---- Provider -------------------------------------------------------

fn make_provider(cfg :: VertexConfig) -> prov.Provider {
  { name: "vertex",
    chat: fn (model :: prov.ModelRef, messages :: List[msg.Message], tools :: List[t.Tool]) -> [net, llm] Iter[d.Delta] {
      chat(cfg, model, messages, tools)
    }
  }
}

fn gemini_35_flash() -> prov.ModelRef {
  { provider: "vertex", model: "gemini-3.5-flash" }
}

fn gemini_35_pro() -> prov.ModelRef {
  { provider: "vertex", model: "gemini-3.5-pro" }
}

fn chat(cfg :: VertexConfig, model :: prov.ModelRef, messages :: List[msg.Message], tools :: List[t.Tool]) -> [net, llm] Iter[d.Delta] {
  let url     := vertex_url(cfg, model.model)
  let headers := build_headers(cfg)
  let body    := build_request(messages, tools)
  let lines := match http.stream_lines(url, headers, body) {
    Err(_) => [],
    Ok(it)  => iter.to_list(it),
  }
  parse_ndjson_stream(lines)
}

# ---- Request (Gemini wire format) -----------------------------------

fn build_request(messages :: List[msg.Message], tools :: List[t.Tool]) -> Str {
  let sys_and_contents := encode_messages(messages)
  let sys_opt  := match sys_and_contents { (s, _) => s }
  let contents := match sys_and_contents { (_, c) => c }
  let base := [("contents", JList(contents))]
  let with_sys := match sys_opt {
    None    => base,
    Some(s) => list.concat(base, [("systemInstruction", JObj([("parts", JList([JObj([("text", JStr(s))])]))]))]),
  }
  let with_tools := if list.is_empty(tools) { with_sys } else {
    list.concat(with_sys, [("tools", JList([JObj([("functionDeclarations", JList(list.map(tools, t.to_google_json)))])]))])
  }
  jv.stringify(JObj(with_tools))
}

fn encode_messages(messages :: List[msg.Message]) -> (Option[Str], List[jv.Json]) {
  let sys := list.fold(messages, None, fn (acc :: Option[Str], m :: msg.Message) -> Option[Str] {
    match m { SystemMsg(s) => Some(s), _ => acc }
  })
  let contents := list.fold(messages, [], fn (acc :: List[jv.Json], m :: msg.Message) -> List[jv.Json] {
    match m { SystemMsg(_) => acc, _ => list.concat(acc, [encode_content(m)]) }
  })
  (sys, contents)
}

fn encode_content(m :: msg.Message) -> jv.Json {
  match m {
    UserMsg(text) =>
      JObj([("role", JStr("user")), ("parts", JList([JObj([("text", JStr(text))])]))]),
    AssistantMsg(text, calls) => if list.is_empty(calls) {
      JObj([("role", JStr("model")), ("parts", JList([JObj([("text", JStr(text))])]))])
    } else {
      JObj([("role", JStr("model")), ("parts", JList(list.map(calls, fn (c :: msg.ToolCall) -> jv.Json {
        JObj([("functionCall", JObj([("name", JStr(c.name)), ("args", c.args)]))])
      })))])
    },
    ToolMsg(call_id, content) => {
      let fn_name      := if str.starts_with(call_id, "call_") { str.slice(call_id, 5, str.len(call_id)) } else { call_id }
      let response_obj := JObj([("output", JStr(content))])
      let fn_response  := JObj([("name", JStr(fn_name)), ("response", response_obj)])
      let part         := JObj([("functionResponse", fn_response)])
      JObj([("role", JStr("user")), ("parts", JList([part]))])
    },
    SystemMsg(_) => JObj([("role", JStr("user")), ("parts", JList([JObj([("text", JStr(""))])]))]),
  }
}

# ---- NDJSON response parsing (Gemini format) ------------------------

fn parse_ndjson_stream(lines :: List[Str]) -> Iter[d.Delta] {
  let deltas := list.fold(lines, [], fn (acc :: List[d.Delta], line :: Str) -> List[d.Delta] {
    let t := str.trim(line)
    if str.is_empty(t) { acc } else {
      match jv.parse_into_errors(t) {
        Err(_) => acc,
        Ok(j)  => list.concat(acc, parse_chunk(j)),
      }
    }
  })
  iter.from_list(deltas)
}

fn parse_chunk(j :: jv.Json) -> List[d.Delta] {
  match jv.get_field(j, "candidates") {
    Some(JList(cands)) => match list.head(cands) {
      None    => [],
      Some(c) => parse_candidate(c),
    },
    _ => [],
  }
}

fn parse_candidate(cand :: jv.Json) -> List[d.Delta] {
  let content_deltas := match jv.get_field(cand, "content") {
    None    => [],
    Some(c) => parse_parts(c),
  }
  let finish_deltas := match jv.get_field(cand, "finishReason") {
    Some(JStr(r)) => [FinishDelta(normalise_finish(r))],
    _ => [],
  }
  list.concat(content_deltas, finish_deltas)
}

fn parse_parts(content :: jv.Json) -> List[d.Delta] {
  match jv.get_field(content, "parts") {
    Some(JList(parts)) => list.fold(parts, [], fn (acc :: List[d.Delta], part :: jv.Json) -> List[d.Delta] {
      list.concat(acc, parse_part(part))
    }),
    _ => [],
  }
}

fn parse_part(part :: jv.Json) -> List[d.Delta] {
  match jv.get_field(part, "text") {
    Some(JStr(s)) => if str.is_empty(s) { [] } else { [TextChunk(s)] },
    _ => match jv.get_field(part, "functionCall") {
      Some(fc) => {
        let name := str_field(fc, "name")
        let id   := str.concat("call_", name)
        let args := match jv.get_field(fc, "args") { Some(aj) => jv.stringify(aj), None => "{}" }
        [ToolCallBegin(id, name), ToolArgChunk(id, args)]
      },
      None => [],
    },
  }
}

fn normalise_finish(reason :: Str) -> Str {
  match reason {
    "STOP"       => "stop",
    "MAX_TOKENS" => "length",
    "SAFETY"     => "content_filter",
    other        => other,
  }
}

fn str_field(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) { Some(JStr(s)) => s, _ => "" }
}

# lex-oms-agent — Demo 3: A2A-Compliant Trading Agent Server
#
# Exposes the OMS trading agent as a Google Agent2Agent (A2A) service.
# Any A2A-compatible client can send natural-language trading goals and
# receive results back over JSON-RPC 2.0.
#
# Skill:  execute_trade_goal
#   Input:  { "text": "<natural language trading goal>" }
#   Output: summary text + blotter / positions / risk as artifacts
#
# The shared OMS DB is initialised once at startup. Positions persist
# across tasks for the lifetime of the server process.
#
# Run:
#   ANTHROPIC_API_KEY=sk-ant-... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/a2a_agent.lex main
#
# Discovery:
#   curl http://localhost:4041/.well-known/agent.json
#
# Submit a task:
#   curl -X POST http://localhost:4041/ \
#     -H 'content-type: application/json' \
#     -d '{"jsonrpc":"2.0","id":1,"method":"tasks/send","params":{
#           "id":"t_1","contextId":"ctx_1","skill":"execute_trade_goal",
#           "message":{"kind":"message","messageId":"m1","role":"user",
#                      "parts":[{"type":"text","text":
#                        "Buy 100 AAPL and 50 MSFT at market. Call done when both are accepted."}]}}}'

import "std.io" as io

import "std.net" as net

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.map" as map

import "std.env" as env

import "lex-orm/src/connection" as conn

import "lex-orm/src/error" as dbe

import "lex-trail/src/log" as trail_log

import "lex-llm/provider" as prov

import "lex-schema/constraints" as c

import "lex-schema/schema" as sch

import "lex-spec/spec" as sp

import "lex-spec/capability" as cap

import "lex-web/router" as router

import "lex-web/middleware" as mw

import "lex-agent/src/agent_card" as card

import "lex-agent/src/server" as a2a

import "lex-agent/src/mount" as mount

import "lex-agent/src/message" as msg

import "lex-agent/src/task" as tk

import "lex-oms/src/server" as srv

import "../src/agent" as oms_agent

import "lex-llm/src/providers/anthropic" as anth

import "lex-llm/src/providers/vertex" as vertex

import "../src/llm_decide" as llm_decide

# ---- Provider selection --------------------------------------------
fn get_env(key :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => v,
    None => "",
  }
}

fn select_provider() -> [env] prov.Provider {
  match get_env("LLM_PROVIDER") {
    "vertex" => {
      let project := get_env("VERTEX_PROJECT")
      let location := get_env("VERTEX_LOCATION")
      let token := get_env("VERTEX_ACCESS_TOKEN")
      let api_key := get_env("VERTEX_API_KEY")
      let access_token := if str.is_empty(token) {
        api_key
      } else {
        token
      }
      let cfg := if str.is_empty(location) {
        vertex.default_config(access_token, project)
      } else {
        vertex.config_at(access_token, project, location)
      }
      vertex.make_provider(cfg)
    },
    _ => anth.make_provider(anth.default_config(get_env("ANTHROPIC_API_KEY"))),
  }
}

fn select_model() -> [env] prov.ModelRef {
  match get_env("LLM_PROVIDER") {
    "vertex" => {
      let m := get_env("VERTEX_MODEL")
      if str.is_empty(m) {
        vertex.gemini_35_flash()
      } else {
        { provider: "vertex", model: m }
      }
    },
    _ => {
      let m := get_env("ANTHROPIC_MODEL")
      if str.is_empty(m) {
        prov.claude_haiku()
      } else {
        { provider: "anthropic", model: m }
      }
    },
  }
}

# ---- Capability + precondition -------------------------------------
fn nonempty_goal_spec() -> sp.Spec {
  { name: "nonempty_goal", quantifiers: [QRecord({ name: "args", fields: [{ name: "text", ty: TStr }] })], predicate: EBinop({ op: "!=", lhs: EField({ binding: "args", field: "text" }), rhs: EConst(VStr("")) }) }
}

fn trade_capability() -> cap.Capability {
  let base := cap.inbound("execute_trade_goal", "Execute a natural-language trading goal against the live OMS. Returns outcome summary plus blotter, positions, and risk as artifacts.", { title: "TradeGoalArgs", description: "A natural-language trading instruction.", fields: [sch.required_str("text", [StrNonEmpty])] })
  cap.with_precondition(base, nonempty_goal_spec())
}

# ---- Handler -------------------------------------------------------
fn first_text(parts :: List[msg.Part]) -> Str {
  match list.head(parts) {
    Some(TextPart(s)) => s,
    _ => "",
  }
}

fn get_ctx() -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  { method: "GET", path: "/", query: "", body: "", path_params: map.new(), headers: map.new(), state: map.new() }
}

fn make_handler(db :: conn.ConnDb, log :: trail_log.Log, provider :: prov.Provider, model :: prov.ModelRef) -> (msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] a2a.HandlerOutcome {
  fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] a2a.HandlerOutcome {
    let goal := first_text(m.parts)
    let ctx := { db: db, log: log, max_steps: 20, clock: ClockWall }
    let decide := llm_decide.make_decide(provider, model, goal)
    let result := oms_agent.run_with_llm(ctx, decide)
    let summary := match result {
      GoalMet(r) => "Goal met: " + r,
      StepLimitReached(n) => "Step limit reached after " + int.to_str(n) + " steps",
    }
    let blotter := srv.get_blotter(db, get_ctx()).body
    let positions := srv.get_positions(db, get_ctx()).body
    let risk := srv.get_risk(db, get_ctx()).body
    let artifacts := [{ name: "blotter", index: 0, parts: [TextPart(blotter)] }, { name: "positions", index: 1, parts: [TextPart(positions)] }, { name: "risk", index: 2, parts: [TextPart(risk)] }]
    { next_state: TSCompleted, reply: Some(msg.agent_text(summary)), artifacts: artifacts }
  }
}

# ---- Agent assembly ------------------------------------------------
fn make_agent(db :: conn.ConnDb, log :: trail_log.Log, provider :: prov.Provider, model :: prov.ModelRef) -> a2a.AgentDef {
  let c := card.make("lex-oms-agent", "LLM-backed OMS trading agent — accepts natural-language goals, executes via a typed tool loop, returns blotter/positions/risk artifacts.", "0.1.0", "http://localhost:4041", [trade_capability()])
  let skill := { capability: trade_capability(), handle: make_handler(db, log, provider, model) }
  a2a.make_agent_def(c, [skill])
}

# ---- HTTP server ---------------------------------------------------
fn app(db :: conn.ConnDb, log :: trail_log.Log, provider :: prov.Provider, model :: prov.ModelRef) -> router.Router {
  let base := router.new()
  let with_mw := router.use_mw(router.use_mw(router.use_mw(router.use_mw(base, mw.body_limit(1048576)), mw.request_id()), mw.gzip(1024)), mw.logger())
  mount.mount(with_mw, make_agent(db, log, provider, model))
}

fn handle(db :: conn.ConnDb, log :: trail_log.Log, provider :: prov.Provider, model :: prov.ModelRef, req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Response {
  let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
  let r := router.dispatch(app(db, log, provider, model), raw)
  { status: r.status, body: BodyStr(r.body), headers: r.headers }
}

fn err_response(msg_str :: Str) -> Response {
  { status: 500, body: BodyStr(msg_str), headers: map.new() }
}

fn main() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc, env] Nil {
  let provider := select_provider()
  let model := select_model()
  match conn.connect_sqlite(":memory:") {
    Err(e) => {
      let __e := io.print("db error: " + dbe.message(e))
      net.serve_fn(4041, fn (_r :: Request) -> Response {
        err_response("db init failed")
      })
    },
    Ok(db) => match trail_log.open_memory() {
      Err(m) => {
        let __e := io.print("trail error: " + m)
        net.serve_fn(4041, fn (_r :: Request) -> Response {
          err_response("trail init failed")
        })
      },
      Ok(log) => {
        let __init := srv.init_db(db)
        let __msg1 := io.print("lex-oms-agent A2A server listening on :4041")
        let __msg2 := io.print("AgentCard: http://localhost:4041/.well-known/agent.json")
        net.serve_fn(4041, fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Response {
          handle(db, log, provider, model, req)
        })
      },
    },
  }
}


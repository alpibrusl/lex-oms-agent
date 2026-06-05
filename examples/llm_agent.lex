# lex-agent — LLM-backed trading agent demo
#
# Reads provider config from environment variables and runs the agent
# loop with a real LLM making decisions instead of a scripted function.
#
# Providers:
#   ANTHROPIC_API_KEY              → Claude (claude-haiku by default; set
#                                    ANTHROPIC_MODEL=claude-sonnet-4-6 for Sonnet)
#   VERTEX_PROJECT + VERTEX_REGION + VERTEX_TOKEN (Bearer) OR VERTEX_API_KEY
#                                  → Gemini 3.5 on Vertex AI
#
# Set LLM_PROVIDER=anthropic (default) or vertex to select the backend.
#
# Run:
#   ANTHROPIC_API_KEY=sk-ant-... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/llm_agent.lex main
#
# For Vertex AI:
#   LLM_PROVIDER=vertex \
#   VERTEX_PROJECT=my-project VERTEX_REGION=us-central1 VERTEX_TOKEN=ya29... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/llm_agent.lex main

import "std.io"   as io
import "std.list" as list
import "std.str"  as str
import "std.int"  as int
import "std.env"  as env
import "std.map"  as map

import "lex-orm/src/connection"  as conn
import "lex-orm/src/error"       as dbe
import "lex-trail/src/log"       as trail_log

import "lex-llm/provider" as prov

import "lex-oms/src/server" as srv

import "../src/agent"              as agent
import "../src/anthropic_provider" as anth
import "../src/vertex_provider"    as vertex
import "../src/llm_decide"         as llm_decide

# ---- Provider selection from env ------------------------------------

fn get_env(key :: Str) -> [env] Str {
  match env.get(key) { Some(v) => v, None => "" }
}

fn make_anthropic_provider() -> [env] prov.Provider {
  anth.make_provider(anth.default_config(get_env("ANTHROPIC_API_KEY")))
}

fn make_vertex_provider() -> [env] prov.Provider {
  let project := get_env("VERTEX_PROJECT")
  let region  := get_env("VERTEX_REGION")
  let token   := get_env("VERTEX_TOKEN")
  let api_key := get_env("VERTEX_API_KEY")
  let cfg := if str.is_empty(token) {
    vertex.api_key_config(project, region, api_key)
  } else {
    vertex.bearer_config(project, region, token)
  }
  vertex.make_provider(cfg)
}

fn select_provider() -> [env] prov.Provider {
  match get_env("LLM_PROVIDER") {
    "vertex" => make_vertex_provider(),
    _        => make_anthropic_provider(),
  }
}

fn select_model() -> [env] prov.ModelRef {
  match get_env("LLM_PROVIDER") {
    "vertex" => {
      let m := get_env("VERTEX_MODEL")
      if str.is_empty(m) { vertex.gemini_35_flash() } else { { provider: "vertex", model: m } }
    },
    _ => {
      let m := get_env("ANTHROPIC_MODEL")
      if str.is_empty(m) { prov.claude_haiku() } else { { provider: "anthropic", model: m } }
    },
  }
}

# ---- Shared helpers ------------------------------------------------

fn get_ctx() -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  { method: "GET", path: "/", query: "", body: "", path_params: map.new(), headers: map.new(), state: map.new() }
}

fn print_section(title :: Str) -> [io] Unit {
  let __h := io.print("")
  io.print("=== " + title + " ===")
}

# ---- Demo runner ---------------------------------------------------

fn run_llm_demo(db :: conn.ConnDb, log :: trail_log.Log, provider :: prov.Provider, model :: prov.ModelRef) -> [sql, time, crypto, net, llm, io] Unit {
  let __init := srv.init_db(db)
  let ctx    := { db: db, log: log, max_steps: 20 }
  let goal   := "Submit market buy orders for AAPL (100 shares), MSFT (50 shares), and NVDA (20 shares). Observe positions after submitting all three. Call done once all orders are confirmed accepted."
  let decide := llm_decide.make_decide(provider, model, goal)

  let __h1   := print_section("LLM AGENT LOOP  [provider=" + provider.name + ", model=" + model.model + "]")
  let result := agent.run_with_llm(ctx, decide)

  let result_line := match result {
    GoalMet(reason)     => "GoalMet: " + reason,
    StepLimitReached(n) => "StepLimitReached at step " + int.to_str(n),
  }
  let __rl := io.print(result_line)

  let __h3 := print_section("GET /blotter")
  let __b  := io.print((srv.get_blotter(db, get_ctx())).body)

  let __h4 := print_section("GET /positions")
  let __p  := io.print((srv.get_positions(db, get_ctx())).body)

  let __h5 := print_section("GET /risk")
  let __r  := io.print((srv.get_risk(db, get_ctx())).body)

  let __h6 := print_section("GET /audit  (agent + trade trail events)")
  io.print((srv.get_audit(log, get_ctx())).body)
}

# ---- Entry point ---------------------------------------------------

fn main() -> [sql, time, crypto, net, llm, io, env, fs_write, concurrent, random, fs_read] Unit {
  let provider := select_provider()
  let model    := select_model()
  match conn.connect_sqlite(":memory:") {
    Err(e)  => io.print("db error: " + dbe.message(e)),
    Ok(db)  => match trail_log.open_memory() {
      Err(m)  => io.print("trail error: " + m),
      Ok(log) => run_llm_demo(db, log, provider, model),
    },
  }
}

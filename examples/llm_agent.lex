# lex-agent — LLM-backed trading agent demo
#
# Reads provider config from environment variables and runs the agent
# loop with a real LLM making decisions instead of a scripted function.
#
# Providers:
#   ANTHROPIC_API_KEY              → Claude (claude-haiku by default; set
#                                    ANTHROPIC_MODEL=claude-sonnet-4-6 for Sonnet)
#   VERTEX_PROJECT + VERTEX_ACCESS_TOKEN (Bearer) OR VERTEX_API_KEY
#                                  → Gemini 3.5 on Vertex AI (VERTEX_LOCATION optional, default "eu")
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
#   VERTEX_PROJECT=my-project VERTEX_ACCESS_TOKEN=ya29... \
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#           examples/llm_agent.lex main

import "std.io" as io

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.env" as env

import "std.map" as map

import "lex-orm/src/connection" as conn

import "lex-orm/src/error" as dbe

import "lex-trail/src/log" as trail_log

import "lex-llm/provider" as prov

import "lex-oms/src/server" as srv

import "../src/agent" as agent

import "lex-llm/src/providers" as providers

import "../src/llm_decide" as llm_decide

# ---- Provider selection from env ------------------------------------
# One backend, chosen by LLM_PROVIDER (default anthropic). Local models work:
#   LLM_PROVIDER=mlx    MLX_URL=http://localhost:8082    (mlx_lm.server)
#   LLM_PROVIDER=ollama OLLAMA_URL=http://localhost:11434
#   LLM_PROVIDER=vllm   VLLM_URL=http://localhost:8000
# Cloud: openai/anthropic/google/mistral (<X>_API_KEY) or vertex
#   (VERTEX_ACCESS_TOKEN + VERTEX_PROJECT [+ VERTEX_LOCATION]).
fn get_env(key :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => v,
    None => "",
  }
}

fn provider_name() -> [env] Str {
  let n := get_env("LLM_PROVIDER")
  if str.is_empty(n) {
    "anthropic"
  } else {
    n
  }
}

fn or_default(v :: Str, def :: Str) -> Str {
  if str.is_empty(v) {
    def
  } else {
    v
  }
}

# Base URL/host (local + OpenAI-compatible servers) or the Vertex location.
fn provider_url(name :: Str) -> [env] Str {
  if name == "mlx" {
    or_default(get_env("MLX_URL"), "http://localhost:8082")
  } else {
    if name == "ollama" {
      or_default(get_env("OLLAMA_URL"), "http://localhost:11434")
    } else {
      if name == "vllm" {
        or_default(get_env("VLLM_URL"), "http://localhost:8000")
      } else {
        if name == "vertex" {
          or_default(get_env("VERTEX_LOCATION"), "eu")
        } else {
          ""
        }
      }
    }
  }
}

# API key for cloud providers; for vertex, the packed "<token>|||<project>".
fn provider_key(name :: Str) -> [env] Str {
  if name == "openai" {
    get_env("OPENAI_API_KEY")
  } else {
    if name == "anthropic" {
      get_env("ANTHROPIC_API_KEY")
    } else {
      if name == "google" {
        get_env("GOOGLE_API_KEY")
      } else {
        if name == "mistral" {
          get_env("MISTRAL_API_KEY")
        } else {
          if name == "vertex" {
            get_env("VERTEX_ACCESS_TOKEN") + "|||" + get_env("VERTEX_PROJECT")
          } else {
            ""
          }
        }
      }
    }
  }
}

fn select_provider() -> [env] prov.Provider {
  let name := provider_name()
  providers.select_provider(name, provider_url(name), provider_key(name))
}

fn default_model(name :: Str) -> prov.ModelRef {
  if name == "vertex" {
    { provider: "vertex", model: "gemini-3.5-flash" }
  } else {
    if name == "mlx" {
      { provider: "mlx", model: "mlx-community/Qwen2.5-7B-Instruct-4bit" }
    } else {
      if name == "ollama" {
        { provider: "ollama", model: "llama3" }
      } else {
        if name == "anthropic" {
          prov.claude_haiku()
        } else {
          { provider: name, model: "" }
        }
      }
    }
  }
}

fn select_model() -> [env] prov.ModelRef {
  let name := provider_name()
  let m := get_env("LLM_MODEL")
  if str.is_empty(m) {
    default_model(name)
  } else {
    { provider: name, model: m }
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
  let ctx := { db: db, log: log, max_steps: 20, clock: ClockWall }
  let goal := "Submit market buy orders for AAPL (100 shares), MSFT (50 shares), and NVDA (20 shares). Observe positions after submitting all three. Call done once all orders are confirmed accepted."
  let decide := llm_decide.make_decide(provider, model, goal)
  let __h1 := print_section("LLM AGENT LOOP  [provider=" + provider.name + ", model=" + model.model + "]")
  let result := agent.run_with_llm(ctx, decide)
  let result_line := match result {
    GoalMet(reason) => "GoalMet: " + reason,
    StepLimitReached(n) => "StepLimitReached at step " + int.to_str(n),
  }
  let __rl := io.print(result_line)
  let __h3 := print_section("GET /blotter")
  let __b := io.print(srv.get_blotter(db, get_ctx()).body)
  let __h4 := print_section("GET /positions")
  let __p := io.print(srv.get_positions(db, get_ctx()).body)
  let __h5 := print_section("GET /risk")
  let __r := io.print(srv.get_risk(db, get_ctx()).body)
  let __h6 := print_section("GET /audit  (agent + trade trail events)")
  io.print(srv.get_audit(log, get_ctx()).body)
}

# ---- Entry point ---------------------------------------------------
fn main() -> [sql, time, crypto, net, llm, io, env, fs_write, concurrent, random, fs_read] Unit {
  let provider := select_provider()
  let model := select_model()
  match conn.connect_sqlite(":memory:") {
    Err(e) => io.print("db error: " + dbe.message(e)),
    Ok(db) => match trail_log.open_memory() {
      Err(m) => io.print("trail error: " + m),
      Ok(log) => run_llm_demo(db, log, provider, model),
    },
  }
}


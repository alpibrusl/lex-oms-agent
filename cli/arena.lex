# arena — Lex-native CLI for Lex Arena
#
# Built on the lex-cli framework (config + authenticated HTTP). Each
# subcommand is a function invoked via `lex run`; the thin `cli/arena`
# launcher maps the friendly `arena run -e .. -a ..` form onto these.
#
#   lex run cli/arena.lex episodes
#   lex run cli/arena.lex run_cmd     "ep1-baseline" "python3 agent.py" "out.jsonl"
#   lex run cli/arena.lex verify_cmd  "ep1-baseline" "out.jsonl"
#   lex run cli/arena.lex login       "https://loom.alpibru.com" "<token>"
#   lex run cli/arena.lex submit      "ep1-baseline" "out.jsonl" "me" "open" "gpt-4o"
#   lex run cli/arena.lex publish     "ep1-baseline" "python3 agent.py" "me" "open" "gpt-4o"
#
# Running an episode replays the deterministic sim in-process (no second
# `lex` subprocess) — this binary IS the verifier participants run.
#
# Effects: the networked + sim-running surface; see each fn.

import "std.io" as io
import "std.str" as str
import "std.list" as list
import "std.json" as json
import "std.int" as int

import "lex-cli/config" as config
import "lex-cli/api" as api

import "./scenario_helpers" as sh
import "../src/arena/runner" as runner
import "../src/arena/verify" as verify

fn tool() -> Str { "lex-arena" }
fn default_api() -> Str { "https://loom.alpibru.com" }
fn scenario_tmp() -> Str { "/tmp/arena-cli-scenario.json" }

# ---- config resolution ------------------------------------------------

fn base_url() -> [io, env] Str {
  let cfg := config.load(tool())
  config.resolve("", "ARENA_API", cfg.api, default_api())
}

fn auth_token() -> [io, env] Str {
  let cfg := config.load(tool())
  config.resolve("", "ARENA_TOKEN", cfg.token, "")
}

# ---- commands ---------------------------------------------------------

# List the episodes of a season (public; default season "practice").
fn episodes() -> [net, io, env] Int {
  episodes_for("practice")
}

fn episodes_for(season :: Str) -> [net, io, env] Int {
  let base := base_url()
  let res := api.get_json(base, "/api/arena/seasons/" + season + "/episodes", "")
  if res.ok {
    match sh.parse_episodes(res.body) {
      Err(e) => { let __e := io.print("parse error: " + e) 1 },
      Ok(eps) => {
        let __h := io.print("Episodes in season '" + season + "':")
        let __l := list.map(eps, fn (ep :: sh.EpisodeRec) -> [io] Unit {
          io.print("  " + ep.slug + (if ep.is_practice { "  (practice)" } else { "" }) + "  ·  sim v" + ep.sim_version)
        })
        0
      },
    }
  } else {
    let __e := io.print("error (" + int.to_str(res.status) + "): " + res.error)
    1
  }
}

# Run an agent against an episode → trail file (in-process sim).
fn run_cmd(slug :: Str, agent_cmd :: Str, out_path :: Str) -> [net, sql, time, crypto, io, fs_read, fs_write, proc, env] Int {
  let base := base_url()
  match fetch_scenario(base, "practice", slug) {
    Err(e) => { let __e := io.print(e) 1 },
    Ok(_) => runner.run_agent(scenario_tmp(), agent_cmd, out_path),
  }
}

# Replay-verify a trail locally before submitting.
fn verify_cmd(slug :: Str, trail_path :: Str) -> [net, sql, time, crypto, io, fs_read, fs_write, env] Int {
  let base := base_url()
  match fetch_scenario(base, "practice", slug) {
    Err(e) => { let __e := io.print(e) 1 },
    Ok(_) => verify.verify(scenario_tmp(), trail_path),
  }
}

# Store API base + token in ~/.config/lex-arena/config.json.
fn login(base :: Str, tok :: Str) -> [io, fs_write, env] Int {
  let api_base := if str.is_empty(base) { default_api() } else { base }
  match config.save(tool(), { api: api_base, token: tok }) {
    Err(e) => { let __e := io.print("save failed: " + e) 1 },
    Ok(_) => { let __p := io.print("Saved token for " + api_base) 0 },
  }
}

# Upload a trail file to an episode (needs login).
fn submit(slug :: Str, trail_path :: Str, name :: Str, division :: Str, model :: Str) -> [net, io, fs_read, env] Int {
  let base := base_url()
  let tok := auth_token()
  if str.is_empty(tok) {
    let __e := io.print("not logged in — run `arena login` (or set ARENA_TOKEN)")
    1
  } else {
    match resolve_episode_id(base, "practice", slug) {
      Err(e) => { let __e := io.print(e) 1 },
      Ok(epid) => match io.read(trail_path) {
        Err(_) => { let __e := io.print("cannot read trail: " + trail_path) 1 },
        Ok(trail) => {
          let body := sh.submit_body(trail, name, division, model)
          let res := api.post_json(base, "/api/arena/episodes/" + epid + "/entries", body, tok)
          if res.ok {
            let __p := io.print("Submitted: " + res.body)
            0
          } else {
            let __e := io.print("submit failed (" + int.to_str(res.status) + "): " + res.error + " " + res.body)
            1
          }
        },
      },
    }
  }
}

# run + submit in one step.
fn publish(slug :: Str, agent_cmd :: Str, name :: Str, division :: Str, model :: Str) -> [net, sql, time, crypto, io, fs_read, fs_write, proc, env] Int {
  let out_path := slug + "-trail.jsonl"
  let rc := run_cmd(slug, agent_cmd, out_path)
  if rc == 0 {
    submit(slug, out_path, name, division, model)
  } else {
    rc
  }
}

# ---- helpers ----------------------------------------------------------

# Fetch the episode's scenario JSON from the API and write it to the temp
# path the sim reads. Errors if the scenario is withheld (scoring seeds).
fn fetch_scenario(base :: Str, season :: Str, slug :: Str) -> [net, io, fs_write, env] Result[Unit, Str] {
  let res := api.get_json(base, "/api/arena/seasons/" + season + "/episodes", "")
  if not res.ok {
    Err("could not load episodes (" + int.to_str(res.status) + ")")
  } else {
    match sh.find_episode(res.body, slug) {
      Err(e) => Err(e),
      Ok(ep) => if str.is_empty(ep.scenario_json) {
        Err("scenario for '" + slug + "' is withheld (scoring seeds revealed when the season closes)")
      } else {
        match io.write(scenario_tmp(), ep.scenario_json) {
          Err(_) => Err("could not write scenario temp file"),
          Ok(_) => Ok(()),
        }
      },
    }
  }
}

fn resolve_episode_id(base :: Str, season :: Str, slug :: Str) -> [net, env] Result[Str, Str] {
  let res := api.get_json(base, "/api/arena/seasons/" + season + "/episodes", "")
  if not res.ok {
    Err("could not load episodes (" + int.to_str(res.status) + ")")
  } else {
    match sh.find_episode(res.body, slug) {
      Err(e) => Err(e),
      Ok(ep) => Ok(ep.id),
    }
  }
}

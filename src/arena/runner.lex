# lex-arena — runner: drive an external agent process through an episode
#
# The participant's agent is ANY executable, in any language. Protocol
# (one-shot per step — see docs/arena-protocol.md):
#
#   1. The runner writes a request JSON file with the episode state.
#   2. It invokes:  <agent_cmd> <request_path>
#   3. The agent prints exactly one tool-call JSON object to stdout
#      (the same format the trail records in decision.intent "call"):
#        {"t":"submit","cl_ord_id":"A1","symbol":"AAPL","side":"buy",
#         "quantity":100,"orig_cl_ord_id":"","target":"","reason":""}
#   4. The runner executes it against the sim and repeats.
#
# Agent failures (unparseable output, spawn error) terminate the
# episode with AgentDone("agent error: ...") — recorded in the trail,
# so a broken agent produces an honest, verifiable record of breaking.
#
# Run:
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#     src/arena/runner.lex run_agent '"scenarios/ep1.json"' '"python3 my_agent.py"' '"/tmp/my_trail.jsonl"'

import "std.io" as io
import "std.str" as str
import "std.int" as int
import "std.list" as list
import "std.json" as json
import "std.proc" as proc

import "lex-orm/src/connection" as conn
import "lex-trail/src/log" as trail_log

import "lex-oms/src/server" as srv

import "../agent" as agent
import "../tool" as tool
import "./scenario" as scenario
import "./trail_file" as tf
import "./fills" as fills

# ---- Request building --------------------------------------------------

fn esc(s :: Str) -> Str {
  str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\"")
}

fn history_compact(history :: List[agent.Step]) -> Str {
  str.join(list.map(history, fn (s :: agent.Step) -> Str {
    int.to_str(s.step) + ":" + tool.tool_name(s.tool) + ":" + (if s.outcome.ok { "ok" } else { "fail" }) + ":" + int.to_str(s.outcome.status)
  }), "|")
}

fn request_json(sc :: scenario.Scenario, history :: List[agent.Step]) -> Str {
  let n := list.len(history)
  let last_ok := match list.head(list.reverse(history)) {
    None => true,
    Some(s) => s.outcome.ok,
  }
  let last_status := match list.head(list.reverse(history)) {
    None => 0,
    Some(s) => s.outcome.status,
  }
  let last_body := match list.head(list.reverse(history)) {
    None => "",
    Some(s) => s.outcome.body,
  }
  "{\"step\":" + int.to_str(n)
    + ",\"max_steps\":" + int.to_str(sc.max_steps)
    + ",\"scenario\":\"" + sc.name + "\""
    + ",\"last_ok\":" + (if last_ok { "true" } else { "false" })
    + ",\"last_status\":" + int.to_str(last_status)
    + ",\"last_body\":\"" + esc(last_body) + "\""
    + ",\"history\":\"" + esc(history_compact(history)) + "\"}"
}

# ---- External decide ----------------------------------------------------

fn external_decide(sc :: scenario.Scenario, agent_cmd :: Str, req_path :: Str) -> (List[agent.Step]) -> [io, fs_read, fs_write, proc] tool.Tool {
  fn (history :: List[agent.Step]) -> [io, fs_read, fs_write, proc] tool.Tool {
    match io.write(req_path, request_json(sc, history)) {
      Err(e) => AgentDone("agent error: cannot write request: " + e),
      Ok(_) => match proc.spawn("bash", ["-c", agent_cmd + " " + req_path]) {
        Err(e) => AgentDone("agent error: spawn failed: " + e),
        Ok(r) => {
          let out := str.trim(r.stdout)
          if str.is_empty(out) {
            AgentDone("agent error: empty output; stderr: " + str.trim(r.stderr))
          } else {
            let parsed :: Result[tool.ToolCall, Str] := json.parse(out)
            match parsed {
              Err(e) => AgentDone("agent error: bad tool call: " + e),
              Ok(c) => tool.tool_from_call(c),
            }
          }
        },
      },
    }
  }
}

# ---- Episode drive -------------------------------------------------------

fn run_agent(scenario_path :: Str, agent_cmd :: Str, out_path :: Str) -> [sql, time, crypto, io, fs_read, fs_write, proc] Int {
  match io.read(scenario_path) {
    Err(e) => {
      let __p := io.print("{\"error\":\"cannot read scenario: " + e + "\"}")
      1
    },
    Ok(sc_json) => match scenario.from_json(sc_json) {
      Err(e) => {
        let __p := io.print("{\"error\":\"bad scenario: " + e + "\"}")
        1
      },
      Ok(sc) => match conn.connect_sqlite(":memory:") {
        Err(_) => {
          let __p := io.print("{\"error\":\"db open failed\"}")
          1
        },
        Ok(db) => match srv.init_db(db) {
          Err(e) => {
            let __p := io.print("{\"error\":\"init_db failed: " + e + "\"}")
            1
          },
          Ok(_) => match trail_log.open_memory() {
            Err(e) => {
              let __p := io.print("{\"error\":\"log open failed: " + e + "\"}")
              1
            },
            Ok(log) => {
              let req_path := out_path + ".req.json"
              let ctx := { db: db, log: log, max_steps: sc.max_steps, clock: scenario.clock(sc) }
              let result := agent.run_external(ctx, external_decide(sc, agent_cmd, req_path))
              match trail_log.range(log, 0, 4000000000000000) {
                Err(e) => {
                  let __p := io.print("{\"error\":\"trail read failed: " + e + "\"}")
                  1
                },
                Ok(evts) => {
                  let lines := list.map(evts, fn (e :: { id :: Str, kind :: Str, parent :: Option[Str], payload_json :: Str, ts_ms :: Int }) -> tf.Line {
                    let p := match e.parent {
                      Some(s) => s,
                      None => "",
                    }
                    { id: e.id, kind: e.kind, parent: p, payload_json: e.payload_json, ts_ms: e.ts_ms }
                  })
                  match io.write(out_path, tf.to_jsonl(lines)) {
                    Err(e) => {
                      let __p := io.print("{\"error\":\"cannot write trail: " + e + "\"}")
                      1
                    },
                    Ok(_) => {
                      let result_s := match result {
                        GoalMet(reason) => "goal_met: " + reason,
                        StepLimitReached(k) => "step_limit: " + int.to_str(k),
                      }
                      let __p := io.print("{\"trail\":\"" + out_path + "\""
                        + ",\"scenario_id\":\"" + scenario.scenario_id(sc) + "\""
                        + ",\"events\":" + int.to_str(list.len(lines))
                        + ",\"fills\":" + int.to_str(fills.fill_count(lines))
                        + ",\"pnl\":\"" + fills.pnl_str(sc, lines) + "\""
                        + ",\"notional\":\"" + fills.notional_str(sc, lines) + "\""
                        + ",\"result\":\"" + esc(result_s) + "\"}")
                      0
                    },
                  }
                },
              }
            },
          },
        },
      },
    },
  }
}

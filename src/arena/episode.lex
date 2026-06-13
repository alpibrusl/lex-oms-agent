# lex-arena — episode runner
#
# Runs a decision function against a fresh sim under a scenario's clock
# and writes the resulting trail file — the artifact a participant
# submits. `verify.verify` replays that file against the same scenario;
# byte-identical trails verify, anything else is rejected with the
# diverging position.
#
# demo_run is a complete worked example: a scripted strategy plays
# scenarios/ep1.json and writes its trail. Use it as the template for
# wiring a real (LLM) agent into an episode.
#
# Run:
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#     src/arena/episode.lex demo_run scenarios/ep1.json /tmp/my_trail.jsonl

import "std.io" as io
import "std.str" as str
import "std.int" as int
import "std.list" as list

import "lex-orm/src/connection" as conn
import "lex-trail/src/log" as trail_log

import "lex-oms/src/server" as srv

import "../agent" as agent
import "../tool" as tool
import "./scenario" as scenario
import "./trail_file" as tf

type EpisodeOut = { lines :: List[tf.Line], result :: agent.AgentResult }

# Run one episode: fresh in-memory OMS + trail, scenario clock, the
# given decision function. Returns the full trail as lines.
fn run_episode(sc :: scenario.Scenario, decide :: (List[agent.Step]) -> tool.Tool) -> [sql, time, crypto, fs_write] Result[EpisodeOut, Str] {
  match conn.connect_sqlite(":memory:") {
    Err(_) => Err("episode: db open failed"),
    Ok(db) => match srv.init_db(db) {
      Err(e) => Err("episode: init_db failed: " + e),
      Ok(_) => match scenario.seed_marks(db, sc) {
      Err(e) => Err("episode: seed_marks failed: " + e),
      Ok(_) => match trail_log.open_memory() {
        Err(e) => Err("episode: log open failed: " + e),
        Ok(log) => {
          let ctx := { db: db, log: log, max_steps: sc.max_steps, clock: scenario.clock(sc) }
          let result := agent.run(ctx, decide)
          match trail_log.range(log, 0, 4000000000000000) {
            Err(e) => Err("episode: trail read failed: " + e),
            Ok(evts) => {
              let lines := list.map(evts, fn (e :: { id :: Str, kind :: Str, parent :: Option[Str], payload_json :: Str, ts_ms :: Int }) -> tf.Line {
                let p := match e.parent {
                  Some(s) => s,
                  None => "",
                }
                { id: e.id, kind: e.kind, parent: p, payload_json: e.payload_json, ts_ms: e.ts_ms }
              })
              Ok({ lines: lines, result: result })
            },
          }
        },
      },
      },
    },
  }
}

# ---- Demo strategy ----------------------------------------------------
# Observe the blotter, take two positions, check risk, declare done.
fn demo_decide(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 { Observe(Blotter) }
  else { if n == 1 { SubmitOrder({ cl_ord_id: "ARENA-001", symbol: "AAPL", side: "buy", quantity: 100 }) }
  else { if n == 2 { SubmitOrder({ cl_ord_id: "ARENA-002", symbol: "MSFT", side: "buy", quantity: 50 }) }
  else { if n == 3 { Observe(Risk) }
  else { AgentDone("two positions taken within limits") } } } }
}

# Run the demo strategy against a scenario and write the trail file.
fn demo_run(scenario_path :: Str, out_path :: Str) -> [sql, time, crypto, fs_read, fs_write, io] Int {
  match io.read(scenario_path) {
    Err(e) => {
      let __p := io.print("cannot read scenario: " + e)
      1
    },
    Ok(sc_json) => match scenario.from_json(sc_json) {
      Err(e) => {
        let __p := io.print("bad scenario: " + e)
        1
      },
      Ok(sc) => match run_episode(sc, demo_decide) {
        Err(e) => {
          let __p := io.print(e)
          1
        },
        Ok(out) => match io.write(out_path, tf.to_jsonl(out.lines)) {
          Err(e) => {
            let __p := io.print("cannot write trail: " + e)
            1
          },
          Ok(_) => {
            let __p := io.print("{\"trail\":\"" + out_path + "\",\"events\":" + int.to_str(list.len(out.lines)) + ",\"scenario_id\":\"" + scenario.scenario_id(sc) + "\"}")
            0
          },
        },
      },
    },
  }
}

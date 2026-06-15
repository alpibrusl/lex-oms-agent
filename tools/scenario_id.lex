# lex-arena — print the scenario_id of a scenario JSON file
#
# The scenario_id is the content-addressed SHA-256 the verifier pins (see
# src/arena/scenario.lex canonical/scenario_id). Use this to recompute the id
# after hand-editing a scenario file — e.g. when adding a cost block to an
# existing frictionless scenario to create a cost-bearing episode.
#
# Run:
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#     tools/scenario_id.lex of '"scenarios/ep2-costs.json"'
#
# Prints one JSON line: {"path":...,"name":...,"scenario_id":...,"canonical":...}

import "std.io" as io

import "../src/arena/scenario" as scenario

fn of(path :: Str) -> [fs_read, crypto, io] Int {
  match io.read(path) {
    Err(e) => {
      let __ := io.print("{\"error\":\"cannot read " + path + ": " + e + "\"}")
      1
    },
    Ok(s) => match scenario.from_json(s) {
      Err(e) => {
        let __ := io.print("{\"error\":\"bad scenario: " + e + "\"}")
        1
      },
      Ok(sc) => {
        let __ := io.print("{\"path\":\"" + path + "\",\"name\":\"" + sc.name
          + "\",\"scenario_id\":\"" + scenario.scenario_id(sc)
          + "\",\"canonical\":\"" + scenario.canonical(sc) + "\"}")
        0
      },
    },
  }
}

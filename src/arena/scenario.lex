# lex-arena — scenario format
#
# A scenario pins everything an episode needs to be replay-verifiable:
# the sim clock (start + tick), the step budget, and a format version.
# The scenario id is the SHA-256 of the canonical content string, so a
# verdict can reference the exact scenario it was computed against —
# replay must pin scenario + sim version forever.
#
# scenario.json:
#   {
#     "version": "1",
#     "name": "ep1-baseline",
#     "seed": 42,
#     "episode_start_ms": 1700000000000,
#     "tick_ms": 1000,
#     "max_steps": 25
#   }
#
# seed is reserved for randomized market regimes (fills are scripted in
# v0); it participates in the scenario id so future randomized scenarios
# stay content-addressed.
#
# Effects: none. All functions are pure.

import "std.int" as int
import "std.str" as str
import "std.json" as json
import "std.crypto" as crypto

import "../agent" as agent

type Scenario = {
  version          :: Str,
  name             :: Str,
  seed             :: Int,
  episode_start_ms :: Int,
  tick_ms          :: Int,
  max_steps        :: Int,
}

# Parse scenario JSON. Field mismatch surfaces as Err.
fn from_json(s :: Str) -> Result[Scenario, Str] {
  let parsed :: Result[Scenario, Str] := json.parse(s)
  parsed
}

# Canonical content string — field order fixed, unit-separator delimited
# (same convention as lex-trail's event id).
fn canonical(sc :: Scenario) -> Str {
  str.join([sc.version, sc.name, int.to_str(sc.seed), int.to_str(sc.episode_start_ms), int.to_str(sc.tick_ms), int.to_str(sc.max_steps)], " ")
}

# Content-addressed scenario id.
fn scenario_id(sc :: Scenario) -> Str {
  crypto.sha256_str(canonical(sc))
}

# The sim clock this scenario prescribes.
fn clock(sc :: Scenario) -> agent.Clock {
  ClockSim(sc.episode_start_ms, sc.tick_ms)
}

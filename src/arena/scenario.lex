# lex-arena — scenario format
#
# A scenario pins everything an episode needs to be replay-verifiable:
# the sim clock (start + tick), the step budget, the instrument price
# scripts, and a format version. The scenario id is the SHA-256 of the
# canonical content string, so a verdict can reference the exact
# scenario it was computed against — replay must pin scenario + sim
# version forever.
#
# scenario.json (format version 2):
#   {
#     "version": "2",
#     "name": "ep1-baseline",
#     "seed": 42,
#     "episode_start_ms": 1700000000000,
#     "tick_ms": 1000,
#     "max_steps": 25,
#     "instruments": [
#       {"symbol": "AAPL", "prices": "174.91,175.20,175.05,176.40"},
#       {"symbol": "MSFT", "prices": "418.51,418.90,419.75"}
#     ]
#   }
#
# prices is one decimal string per tick, comma-separated; the price at
# step n is prices[min(n, len-1)] (the last price holds). The final
# entry is the episode's mark price for P&L.
#
# seed is reserved for randomized market regimes (prices are scripted
# in v2); it participates in the scenario id so future randomized
# scenarios stay content-addressed.
#
# Effects: none. All functions are pure.

import "std.int" as int
import "std.str" as str
import "std.list" as list
import "std.json" as json
import "std.crypto" as crypto

import "lex-money/src/decimal" as d
import "lex-positions/src/position" as pos

import "../agent" as agent

type Instrument = { symbol :: Str, prices :: Str }

type Scenario = {
  version          :: Str,
  name             :: Str,
  seed             :: Int,
  episode_start_ms :: Int,
  tick_ms          :: Int,
  max_steps        :: Int,
  instruments      :: List[Instrument],
}

# Parse scenario JSON. Field mismatch surfaces as Err.
fn from_json(s :: Str) -> Result[Scenario, Str] {
  let parsed :: Result[Scenario, Str] := json.parse(s)
  parsed
}

# Canonical content string — field order fixed, unit-separator delimited
# (same convention as lex-trail's event id).
fn canonical(sc :: Scenario) -> Str {
  let inst := str.join(list.map(sc.instruments, fn (i :: Instrument) -> Str { i.symbol + "=" + i.prices }), ";")
  str.join([sc.version, sc.name, int.to_str(sc.seed), int.to_str(sc.episode_start_ms), int.to_str(sc.tick_ms), int.to_str(sc.max_steps), inst], " ")
}

# Content-addressed scenario id.
fn scenario_id(sc :: Scenario) -> Str {
  crypto.sha256_str(canonical(sc))
}

# The sim clock this scenario prescribes.
fn clock(sc :: Scenario) -> agent.Clock {
  ClockSim(sc.episode_start_ms, sc.tick_ms)
}

# ---- Price script lookups ---------------------------------------------

fn price_list(sc :: Scenario, symbol :: Str) -> List[Str] {
  let found := list.fold(sc.instruments, "", fn (acc :: Str, i :: Instrument) -> Str {
    if i.symbol == symbol { i.prices } else { acc }
  })
  if str.is_empty(found) { [] } else { str.split(found, ",") }
}

fn nth_or_last(xs :: List[Str], n :: Int) -> Str {
  let ln := list.len(xs)
  let idx := if n < ln { n } else { ln - 1 }
  list.fold(list.enumerate(xs), "", fn (acc :: Str, pair :: (Int, Str)) -> Str {
    match pair {
      (i, s) => if i == idx { s } else { acc },
    }
  })
}

# Price of symbol at step n ("" if the symbol has no script — orders in
# unscripted symbols fill at no price and score zero P&L).
fn price_at(sc :: Scenario, symbol :: Str, n :: Int) -> Option[d.Decimal] {
  let xs := price_list(sc, symbol)
  if list.is_empty(xs) {
    None
  } else {
    pos.parse_price(str.trim(nth_or_last(xs, n)))
  }
}

# The episode's closing mark for a symbol (last scripted price).
fn final_price(sc :: Scenario, symbol :: Str) -> Option[d.Decimal] {
  let xs := price_list(sc, symbol)
  price_at(sc, symbol, list.len(xs))
}

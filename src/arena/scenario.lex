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
import "lex-orm/src/connection" as conn
import "lex-orm/src/error" as dbe
import "lex-oms/src/marks" as marks

import "../agent" as agent

type Instrument = { symbol :: Str, prices :: Str }

# Execution cost model (see fills.lex). spread_bps is the per-side half-spread;
# impact_bps is the slippage added per `lot` shares of order size (linear market
# impact); fee_bps is a commission as basis points of traded notional and
# fee_per_unit_cents a per-share/contract commission; max_fill caps how many
# shares of one order actually fill (0 = unlimited, the original behavior). All
# zero = frictionless, uncapped, no-commission fills.
type CostModel = { spread_bps :: Int, impact_bps :: Int, lot :: Int, fee_bps :: Int, fee_per_unit_cents :: Int, max_fill :: Int }

type Scenario = {
  version          :: Str,
  name             :: Str,
  seed             :: Int,
  episode_start_ms :: Int,
  tick_ms          :: Int,
  max_steps        :: Int,
  instruments      :: List[Instrument],
  cost             :: CostModel,
}

fn cost_active(c :: CostModel) -> Bool {
  c.spread_bps > 0 or c.impact_bps > 0 or c.fee_bps > 0 or c.fee_per_unit_cents > 0 or c.max_fill > 0
}

# A scenario JSON without a "cost" block is frictionless. Lex's JSON parser
# rejects missing fields, so we splice in a zero default before parsing — this
# keeps every pre-cost scenario (and its scenario_id, see canonical) unchanged.
fn inject_default_cost(s :: Str) -> Str {
  let t := str.trim(s)
  str.slice(t, 0, str.len(t) - 1) + ",\"cost\":{\"spread_bps\":0,\"impact_bps\":0,\"lot\":1,\"fee_bps\":0,\"fee_per_unit_cents\":0,\"max_fill\":0}}"
}

# Older cost blocks may predate a field (fees, then max_fill). The cost object is
# always the last field, so the JSON ends in "}}" — splice the missing field in
# before the cost object's closing brace.
fn inject_field(s :: Str, kv :: Str) -> Str {
  let t := str.trim(s)
  str.slice(t, 0, str.len(t) - 2) + "," + kv + "}}"
}

# Parse scenario JSON. Field mismatch surfaces as Err.
fn from_json(s :: Str) -> Result[Scenario, Str] {
  let with_cost := if str.contains(s, "\"cost\"") { s } else { inject_default_cost(s) }
  let with_fees := if str.contains(with_cost, "\"fee_bps\"") { with_cost } else { inject_field(with_cost, "\"fee_bps\":0,\"fee_per_unit_cents\":0") }
  let with_maxfill := if str.contains(with_fees, "\"max_fill\"") { with_fees } else { inject_field(with_fees, "\"max_fill\":0") }
  let parsed :: Result[Scenario, Str] := json.parse(with_maxfill)
  parsed
}

# Canonical content string — field order fixed, unit-separator delimited
# (same convention as lex-trail's event id). The cost block is appended ONLY
# when active, so frictionless scenarios keep their original scenario_id.
fn canonical(sc :: Scenario) -> Str {
  let inst := str.join(list.map(sc.instruments, fn (i :: Instrument) -> Str { i.symbol + "=" + i.prices }), ";")
  let base := str.join([sc.version, sc.name, int.to_str(sc.seed), int.to_str(sc.episode_start_ms), int.to_str(sc.tick_ms), int.to_str(sc.max_steps), inst], " ")
  if cost_active(sc.cost) {
    base + " cost=" + int.to_str(sc.cost.spread_bps) + "/" + int.to_str(sc.cost.impact_bps) + "/" + int.to_str(sc.cost.lot)
      + "/" + int.to_str(sc.cost.fee_bps) + "/" + int.to_str(sc.cost.fee_per_unit_cents) + "/" + int.to_str(sc.cost.max_fill)
  } else {
    base
  }
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

# The sim timestamp the agent loop stamps for step n (ClockSim formula).
# Marks are keyed by this so the OMS — which reads sim_ts_ms from ctx.state
# — resolves the same scripted price the fill uses at that step.
fn step_ts(sc :: Scenario, n :: Int) -> Int {
  sc.episode_start_ms + n * sc.tick_ms
}

# Seed the OMS marks table with every (symbol, step) scripted price, so the
# pre-trade margin and position-notional gates evaluate against the real
# price an order fills at. Without this the OMS falls back to a static mock
# that doesn't know most symbols → a $0 mark → the gates never fire. Called
# once after init_db, before the agent loop; replay seeds identically, so
# trails stay deterministic.
fn seed_marks(db :: conn.ConnDb, sc :: Scenario) -> [sql] Result[Unit, Str] {
  let steps := list.range(0, sc.max_steps + 1)
  list.fold(sc.instruments, Ok(()), fn (acc :: Result[Unit, Str], inst :: Instrument) -> [sql] Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => list.fold(steps, Ok(()), fn (a2 :: Result[Unit, Str], n :: Int) -> [sql] Result[Unit, Str] {
        match a2 {
          Err(e) => Err(e),
          Ok(_) => match price_at(sc, inst.symbol, n) {
            None => Ok(()),
            Some(p) => match marks.set(db, inst.symbol, step_ts(sc, n), pos.decimal_to_str(p)) {
              Err(e) => Err(dbe.message(e)),
              Ok(_) => Ok(()),
            },
          },
        }
      }),
    }
  })
}

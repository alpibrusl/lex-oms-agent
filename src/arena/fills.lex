# lex-arena — fills + P&L, pure over (trail, scenario)
#
# v2 fill model: every accepted SubmitOrder fills in full at the
# scenario's scripted price for its step; the episode mark is the last
# scripted price. P&L is therefore a PURE function of the trail and the
# scenario — the runner and the verifier compute it with the same code
# on the same inputs, so a verified trail's score cannot be disputed
# separately from the trail itself.
#
#   pnl = Σ over accepted submits:  sign(side) * qty * (final_px - fill_px)
#
# Accepted submits are recovered from the trail: decision.intent events
# carry the full tool call; the decision.made event parented on the
# intent carries ok/status. Orders in symbols without a price script
# contribute zero.
#
# Effects: none. All functions are pure.

import "std.str" as str
import "std.int" as int
import "std.list" as list
import "std.json" as json

import "lex-money/src/decimal" as d
import "lex-positions/src/position" as pos

import "../tool" as tool
import "./scenario" as scenario
import "./trail_file" as tf

type IntentPayload = { step :: Int, tool :: Str, call :: tool.ToolCall }

type MadePayload = { step :: Int, tool :: Str, ok :: Bool, status :: Int }

# One filled order recovered from the trail.
type Fill = { step :: Int, symbol :: Str, side :: Str, quantity :: Int }

# ---- Accepted-submit extraction ---------------------------------------

fn made_ok_parents(lines :: List[tf.Line]) -> List[Str] {
  list.fold(lines, [], fn (acc :: List[Str], l :: tf.Line) -> List[Str] {
    if l.kind == "agent.decision.made" {
      let parsed :: Result[MadePayload, Str] := json.parse(l.payload_json)
      match parsed {
        Err(_) => acc,
        Ok(p) => if p.ok { list.concat(acc, [l.parent]) } else { acc },
      }
    } else {
      acc
    }
  })
}

fn contains(xs :: List[Str], x :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, s :: Str) -> Bool {
    if acc { true } else { s == x }
  })
}

# All submits whose decision.made reported ok.
fn accepted_fills(lines :: List[tf.Line]) -> List[Fill] {
  let ok_parents := made_ok_parents(lines)
  list.fold(lines, [], fn (acc :: List[Fill], l :: tf.Line) -> List[Fill] {
    if l.kind == "agent.decision.intent" and contains(ok_parents, l.id) {
      let parsed :: Result[IntentPayload, Str] := json.parse(l.payload_json)
      match parsed {
        Err(_) => acc,
        Ok(p) => if p.call.t == "submit" {
          list.concat(acc, [{ step: p.step, symbol: p.call.symbol, side: p.call.side, quantity: p.call.quantity }])
        } else {
          acc
        },
      }
    } else {
      acc
    }
  })
}

# ---- P&L ---------------------------------------------------------------

# The price an order actually fills at, given the scenario's cost model.
# Starting from the scripted mid: buys cross the half-spread up and sells down,
# plus linear market impact — impact_bps of slippage per `lot` shares of size,
# so a large order's average fill degrades convexly with size. With a zero cost
# model this returns the mid unchanged (the original frictionless behavior).
fn effective_fill(sc :: scenario.Scenario, f :: Fill, mid :: d.Decimal) -> d.Decimal {
  let lot := if sc.cost.lot > 0 { sc.cost.lot } else { 1 }
  let total_bps := sc.cost.spread_bps + sc.cost.impact_bps * f.quantity / lot
  if total_bps == 0 {
    # Frictionless: return the mid untouched (same value AND scale), so every
    # pre-cost scenario scores byte-for-byte as before.
    mid
  } else {
    let adj := d.mul(mid, d.decimal(total_bps, -4))
    if f.side == "sell" { d.sub(mid, adj) } else { d.add(mid, adj) }
  }
}

fn fill_pnl(sc :: scenario.Scenario, f :: Fill) -> d.Decimal {
  match scenario.price_at(sc, f.symbol, f.step) {
    None => d.zero(),
    Some(mid) => match scenario.final_price(sc, f.symbol) {
      None => d.zero(),
      Some(mark) => {
        let fill_px := effective_fill(sc, f, mid)
        let edge := d.sub(mark, fill_px)
        let signed := if f.side == "sell" { d.negate(edge) } else { edge }
        d.mul(d.from_int(f.quantity), signed)
      },
    },
  }
}

fn episode_pnl(sc :: scenario.Scenario, lines :: List[tf.Line]) -> d.Decimal {
  list.fold(accepted_fills(lines), d.zero(), fn (acc :: d.Decimal, f :: Fill) -> d.Decimal {
    d.add(acc, fill_pnl(sc, f))
  })
}

fn pnl_str(sc :: scenario.Scenario, lines :: List[tf.Line]) -> Str {
  pos.decimal_to_str(episode_pnl(sc, lines))
}

# ---- Notional ----------------------------------------------------------
# Gross notional deployed by one fill: qty × fill price (always positive;
# a sell still consumes the same buying power). Orders in symbols without
# a price script contribute zero, exactly like P&L.

fn fill_notional(sc :: scenario.Scenario, f :: Fill) -> d.Decimal {
  match scenario.price_at(sc, f.symbol, f.step) {
    None => d.zero(),
    Some(fill_px) => d.mul(d.from_int(f.quantity), fill_px),
  }
}

# Total gross notional across all accepted fills. Pure over (trail, scenario).
# Surfaced alongside pnl so the leaderboard can rank by return on deployed
# capital (pnl / notional) instead of raw pnl — making the score reflect
# skill rather than position size.
fn episode_notional(sc :: scenario.Scenario, lines :: List[tf.Line]) -> d.Decimal {
  list.fold(accepted_fills(lines), d.zero(), fn (acc :: d.Decimal, f :: Fill) -> d.Decimal {
    d.add(acc, fill_notional(sc, f))
  })
}

fn notional_str(sc :: scenario.Scenario, lines :: List[tf.Line]) -> Str {
  pos.decimal_to_str(episode_notional(sc, lines))
}

fn fill_count(lines :: List[tf.Line]) -> Int {
  list.len(accepted_fills(lines))
}

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

fn fill_pnl(sc :: scenario.Scenario, f :: Fill) -> d.Decimal {
  match scenario.price_at(sc, f.symbol, f.step) {
    None => d.zero(),
    Some(fill_px) => match scenario.final_price(sc, f.symbol) {
      None => d.zero(),
      Some(mark) => {
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

fn fill_count(lines :: List[tf.Line]) -> Int {
  list.len(accepted_fills(lines))
}

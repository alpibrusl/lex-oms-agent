# lex-agent — typed tool vocabulary + in-process OMS dispatch
#
# Tool is the ADT the decision function proposes each step.
# dispatch() maps each variant to the corresponding OMS handler call.
#
# All dispatch calls are in-process (no network); the lex-os manifest
# (manifests/trading_agent.json) restricts the networked variant to
# the same endpoints when the agent runs under lex-os.
#
# Effects: [sql, time]

import "std.str" as str
import "std.int" as int
import "std.map" as map

import "lex-orm/src/connection" as conn
import "lex-trail/src/log" as trail_log

import "lex-oms/src/server" as srv

# ---- Tool ADT -------------------------------------------------------

type OrderParams = { cl_ord_id :: Str, symbol :: Str, side :: Str, quantity :: Int }
type CancelParams = { cl_ord_id :: Str, orig_cl_ord_id :: Str, symbol :: Str, side :: Str }

type ObserveTarget = Blotter | Positions | Risk | Audit

type Tool = SubmitOrder(OrderParams) | CancelOrder(CancelParams) | Observe(ObserveTarget) | AgentDone(Str)

type ToolOutcome = { ok :: Bool, status :: Int, body :: Str }

# ---- Tool name (for trail payload) ----------------------------------
fn tool_name(t :: Tool) -> Str {
  match t {
    SubmitOrder(p) => "submit_order:" + p.symbol + ":" + p.side + ":" + int.to_str(p.quantity),
    CancelOrder(p) => "cancel_order:" + p.orig_cl_ord_id,
    Observe(Blotter) => "observe:blotter",
    Observe(Positions) => "observe:positions",
    Observe(Risk) => "observe:risk",
    Observe(Audit) => "observe:audit",
    AgentDone(reason) => "done:" + reason,
  }
}

# ---- Tool call JSON (replayable trail payload) -----------------------
# Complete serialization of a Tool — every field always present (empty
# defaults) so a single record type parses any variant back. This is
# what makes a trail self-contained for replay verification: the
# decision.intent event carries the full call, not just a display name.
fn tool_json(t :: Tool) -> Str {
  match t {
    SubmitOrder(p) =>
      "{\"t\":\"submit\",\"cl_ord_id\":\"" + escape_json_str(p.cl_ord_id) + "\",\"symbol\":\"" + escape_json_str(p.symbol) + "\",\"side\":\"" + escape_json_str(p.side) + "\",\"quantity\":" + int.to_str(p.quantity) + ",\"orig_cl_ord_id\":\"\",\"target\":\"\",\"reason\":\"\"}",
    CancelOrder(p) =>
      "{\"t\":\"cancel\",\"cl_ord_id\":\"" + escape_json_str(p.cl_ord_id) + "\",\"symbol\":\"" + escape_json_str(p.symbol) + "\",\"side\":\"" + escape_json_str(p.side) + "\",\"quantity\":0,\"orig_cl_ord_id\":\"" + escape_json_str(p.orig_cl_ord_id) + "\",\"target\":\"\",\"reason\":\"\"}",
    Observe(target) =>
      "{\"t\":\"observe\",\"cl_ord_id\":\"\",\"symbol\":\"\",\"side\":\"\",\"quantity\":0,\"orig_cl_ord_id\":\"\",\"target\":\"" + observe_name(target) + "\",\"reason\":\"\"}",
    AgentDone(reason) =>
      "{\"t\":\"done\",\"cl_ord_id\":\"\",\"symbol\":\"\",\"side\":\"\",\"quantity\":0,\"orig_cl_ord_id\":\"\",\"target\":\"\",\"reason\":\"" + escape_json_str(reason) + "\"}",
  }
}

fn observe_name(target :: ObserveTarget) -> Str {
  match target {
    Blotter => "blotter",
    Positions => "positions",
    Risk => "risk",
    Audit => "audit",
  }
}

# Parse a tool_json call back into a Tool. Inverse of tool_json for
# replay: unknown t falls back to AgentDone so a malformed trail line
# terminates the replay instead of diverging silently.
type ToolCall = { t :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, quantity :: Int, orig_cl_ord_id :: Str, target :: Str, reason :: Str }

fn tool_from_call(c :: ToolCall) -> Tool {
  if c.t == "submit" {
    SubmitOrder({ cl_ord_id: c.cl_ord_id, symbol: c.symbol, side: c.side, quantity: c.quantity })
  } else { if c.t == "cancel" {
    CancelOrder({ cl_ord_id: c.cl_ord_id, orig_cl_ord_id: c.orig_cl_ord_id, symbol: c.symbol, side: c.side })
  } else { if c.t == "observe" {
    Observe(observe_from_name(c.target))
  } else {
    AgentDone(c.reason)
  } } }
}

fn observe_from_name(s :: Str) -> ObserveTarget {
  if s == "positions" { Positions }
  else { if s == "risk" { Risk }
  else { if s == "audit" { Audit }
  else { Blotter } } }
}

# ---- Context helpers (mirrors lex-oms demo pattern) -----------------
# ts_ms is threaded into ctx.state as sim_ts_ms so lex-oms handlers
# stamp their trail events with the same step timestamp the agent loop
# uses — the whole episode trail becomes deterministic under a sim clock.
fn post_ctx(body :: Str, ts_ms :: Int) -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  { method: "POST", path: "/", query: "", body: body, path_params: map.new(), headers: map.from_list([("content-type", "application/json")]), state: map.from_list([("sim_ts_ms", int.to_str(ts_ms))]) }
}

fn get_ctx(ts_ms :: Int) -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  post_ctx("", ts_ms)
}

# ---- JSON helpers ---------------------------------------------------

# Escape backslashes then double-quotes so LLM-supplied strings cannot
# inject extra fields into the JSON body sent to the OMS.
fn escape_json_str(s :: Str) -> Str {
  str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\"")
}

# ---- JSON builders --------------------------------------------------
fn order_json(p :: OrderParams) -> Str {
  "{\"cl_ord_id\":\"" + escape_json_str(p.cl_ord_id) + "\",\"symbol\":\"" + escape_json_str(p.symbol) + "\",\"side\":\"" + escape_json_str(p.side) + "\",\"quantity\":" + int.to_str(p.quantity) + ",\"order_type\":\"market\",\"price\":\"\",\"stop_price\":\"\",\"time_in_force\":\"\",\"account\":\"\",\"trader_id\":\"AGENT\",\"timestamp\":\"\"}"
}

fn cancel_json(p :: CancelParams) -> Str {
  "{\"cl_ord_id\":\"" + escape_json_str(p.cl_ord_id) + "\",\"orig_cl_ord_id\":\"" + escape_json_str(p.orig_cl_ord_id) + "\",\"account\":\"\",\"symbol\":\"" + escape_json_str(p.symbol) + "\",\"side\":\"" + escape_json_str(p.side) + "\",\"order_qty\":0,\"timestamp\":\"\"}"
}

# ---- Dispatch -------------------------------------------------------
# ts_ms: the step timestamp from the agent loop's clock (sim-time under
# ClockSim, wall-clock under ClockWall) — forwarded to OMS handlers via
# the sim_ts_ms state entry so their trail events share it.
fn dispatch(db :: conn.ConnDb, log :: trail_log.Log, t :: Tool, ts_ms :: Int) -> [sql, time] ToolOutcome {
  match t {
    AgentDone(reason) =>
      { ok: true, status: 0, body: "{\"done\":\"" + reason + "\"}" },
    Observe(target) =>
      dispatch_observe(db, log, target, ts_ms),
    SubmitOrder(p) =>
      dispatch_submit(db, log, p, ts_ms),
    CancelOrder(p) =>
      dispatch_cancel(db, log, p, ts_ms),
  }
}

fn dispatch_observe(db :: conn.ConnDb, log :: trail_log.Log, target :: ObserveTarget, ts_ms :: Int) -> [sql, time] ToolOutcome {
  let res := match target {
    Blotter   => srv.get_blotter(db, get_ctx(ts_ms)),
    Positions => srv.get_positions(db, get_ctx(ts_ms)),
    Risk      => srv.get_risk(db, get_ctx(ts_ms)),
    Audit     => srv.get_audit(log, get_ctx(ts_ms)),
  }
  { ok: res.status == 200, status: res.status, body: res.body }
}

fn dispatch_submit(db :: conn.ConnDb, log :: trail_log.Log, p :: OrderParams, ts_ms :: Int) -> [sql, time] ToolOutcome {
  let res := srv.post_orders(db, log, post_ctx(order_json(p), ts_ms))
  { ok: res.status == 201, status: res.status, body: res.body }
}

fn dispatch_cancel(db :: conn.ConnDb, log :: trail_log.Log, p :: CancelParams, ts_ms :: Int) -> [sql, time] ToolOutcome {
  let res := srv.post_cancel(db, log, post_ctx(cancel_json(p), ts_ms))
  { ok: res.status == 200, status: res.status, body: res.body }
}

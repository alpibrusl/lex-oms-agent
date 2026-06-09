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

# ---- Context helpers (mirrors lex-oms demo pattern) -----------------
fn post_ctx(body :: Str) -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  { method: "POST", path: "/", query: "", body: body, path_params: map.new(), headers: map.from_list([("content-type", "application/json")]), state: map.new() }
}

fn get_ctx() -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  post_ctx("")
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
fn dispatch(db :: conn.ConnDb, log :: trail_log.Log, t :: Tool) -> [sql, time] ToolOutcome {
  match t {
    AgentDone(reason) =>
      { ok: true, status: 0, body: "{\"done\":\"" + reason + "\"}" },
    Observe(target) =>
      dispatch_observe(db, log, target),
    SubmitOrder(p) =>
      dispatch_submit(db, log, p),
    CancelOrder(p) =>
      dispatch_cancel(db, log, p),
  }
}

fn dispatch_observe(db :: conn.ConnDb, log :: trail_log.Log, target :: ObserveTarget) -> [sql, time] ToolOutcome {
  let res := match target {
    Blotter   => srv.get_blotter(db, get_ctx()),
    Positions => srv.get_positions(db, get_ctx()),
    Risk      => srv.get_risk(db, get_ctx()),
    Audit     => srv.get_audit(log, get_ctx()),
  }
  { ok: res.status == 200, status: res.status, body: res.body }
}

fn dispatch_submit(db :: conn.ConnDb, log :: trail_log.Log, p :: OrderParams) -> [sql, time] ToolOutcome {
  let res := srv.post_orders(db, log, post_ctx(order_json(p)))
  { ok: res.status == 201, status: res.status, body: res.body }
}

fn dispatch_cancel(db :: conn.ConnDb, log :: trail_log.Log, p :: CancelParams) -> [sql, time] ToolOutcome {
  let res := srv.post_cancel(db, log, post_ctx(cancel_json(p)))
  { ok: res.status == 200, status: res.status, body: res.body }
}

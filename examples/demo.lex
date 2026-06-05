# lex-agent — scripted trading agent demo
#
# Runs a 7-step agent loop in-process (no network, no real LLM).
# The scripted decision function replaces the LLM; every other piece
# of the stack is real: typed tools, OMS pre-trade gate, lex-trail
# audit events, position book, risk snapshot.
#
# Step 0  decide → Observe(Blotter)           → empty blotter
# Step 1  decide → SubmitOrder(AAPL buy 100)  → 201 PendingNew
# Step 2  decide → SubmitOrder(MSFT buy 50)   → 201 PendingNew
# Step 3  decide → SubmitOrder(NVDA buy 20)   → 201 PendingNew
# Step 4  decide → Observe(Blotter)           → 3 orders PendingNew
# Step 5  decide → Observe(Risk)              → portfolio snapshot
# Step 6  decide → Done("3 symbols submitted within grant")
#
# The exchange fills are then injected to populate positions, and
# GET /positions + GET /audit are printed to show the full picture.
#
# Run:
#   lex run --allow-effects concurrent,fs_read,fs_write,io,net,random,sql,time \
#           examples/demo.lex main

import "std.io" as io
import "std.list" as list
import "std.str" as str
import "std.int" as int
import "std.map" as map

import "lex-orm/src/connection" as conn
import "lex-orm/src/error" as dbe
import "lex-trail/src/log" as trail_log

import "lex-oms/src/server" as srv

import "../src/tool" as tool
import "../src/agent" as agent

# ---- Scripted decision function -------------------------------------
#
# In production this function is replaced by an LLM call:
#   fn llm_decide(history) -> Tool { lex_llm.next_action(api_key, goal, history) }
#
# The scripted version below is deterministic and requires no API key.

fn scripted_decide(history :: List[agent.Step]) -> tool.Tool {
  let n := agent.steps_taken(history)
  if n == 0 {
    Observe(Blotter)
  } else {
    if n == 1 {
      SubmitOrder({ cl_ord_id: "AGT-001", symbol: "AAPL", side: "buy", quantity: 100 })
    } else {
      if n == 2 {
        SubmitOrder({ cl_ord_id: "AGT-002", symbol: "MSFT", side: "buy", quantity: 50 })
      } else {
        if n == 3 {
          SubmitOrder({ cl_ord_id: "AGT-003", symbol: "NVDA", side: "buy", quantity: 20 })
        } else {
          if n == 4 {
            Observe(Blotter)
          } else {
            if n == 5 {
              Observe(Risk)
            } else {
              AgentDone("3 symbols submitted within grant: AAPL 100, MSFT 50, NVDA 20")
            }
          }
        }
      }
    }
  }
}

# ---- Exchange fill simulation ---------------------------------------
# Injects ACK + full fill execution reports for each accepted order.
# In production these arrive from the exchange; here we drive them
# directly to populate the position book.

fn post_ctx(body :: Str) -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  { method: "POST", path: "/", query: "", body: body, path_params: map.new(), headers: map.from_list([("content-type", "application/json")]), state: map.new() }
}

fn get_ctx() -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  post_ctx("")
}

fn ack_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"0\",\"ord_status\":\"0\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(qty) + "\",\"cum_qty\":\"0\",\"leaves_qty\":\"" + int.to_str(qty) + "\",\"avg_px\":\"0\",\"last_px\":\"\",\"last_qty\":\"\",\"text\":\"\"}"
}

fn fill_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int, last_px :: Str) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"2\",\"ord_status\":\"2\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(qty) + "\",\"cum_qty\":\"" + int.to_str(qty) + "\",\"leaves_qty\":\"0\",\"avg_px\":\"" + last_px + "\",\"last_px\":\"" + last_px + "\",\"last_qty\":\"" + int.to_str(qty) + "\",\"text\":\"\"}"
}

fn simulate_fills(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  let __a1 := srv.post_execution_reports(db, post_ctx(ack_json("EX-001", "EXCH-001", "AGT-001", "AAPL", "buy", 100)))
  let __f1 := srv.post_execution_reports(db, post_ctx(fill_json("EX-002", "EXCH-001", "AGT-001", "AAPL", "buy", 100, "174.91")))
  let __a2 := srv.post_execution_reports(db, post_ctx(ack_json("EX-003", "EXCH-002", "AGT-002", "MSFT", "buy", 50)))
  let __f2 := srv.post_execution_reports(db, post_ctx(fill_json("EX-004", "EXCH-002", "AGT-002", "MSFT", "buy", 50, "418.51")))
  let __a3 := srv.post_execution_reports(db, post_ctx(ack_json("EX-005", "EXCH-003", "AGT-003", "NVDA", "buy", 20)))
  let __f3 := srv.post_execution_reports(db, post_ctx(fill_json("EX-006", "EXCH-003", "AGT-003", "NVDA", "buy", 20, "875.30")))
  ()
}

# ---- Demo runner ----------------------------------------------------

fn print_section(title :: Str) -> [io] Unit {
  let __h := io.print("")
  io.print("=== " + title + " ===")
}

fn print_step(s :: agent.Step) -> [io] Unit {
  let status_s := if s.outcome.status == 0 { "done" } else { int.to_str(s.outcome.status) }
  io.print("  step " + int.to_str(s.step) + "  " + tool.tool_name(s.tool) + "  →  " + status_s + (if s.outcome.ok { " ✓" } else { " ✗" }))
}

fn run_demo(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, io, crypto] Unit {
  let __init := srv.init_db(db)
  let ctx := { db: db, log: log, max_steps: 20 }

  let __h1 := print_section("AGENT LOOP  (scripted — swap decide fn for real LLM)")
  let result := agent.run(ctx, scripted_decide)

  let __h2 := print_section("STEP LOG")
  # (trail events emitted live; print summary from agent loop result)
  let result_line := match result {
    GoalMet(reason) => "GoalMet: " + reason,
    StepLimitReached(n) => "StepLimitReached at step " + int.to_str(n),
  }
  let __rl := io.print(result_line)

  let __h3 := print_section("EXCHANGE FILLS  (simulating exchange execution reports)")
  let __fx := simulate_fills(db)
  let __ok := io.print("fills injected for AGT-001 AAPL, AGT-002 MSFT, AGT-003 NVDA")

  let __h4 := print_section("GET /blotter")
  let blotter := srv.get_blotter(db, get_ctx())
  let __b := io.print(blotter.body)

  let __h5 := print_section("GET /positions")
  let positions := srv.get_positions(db, get_ctx())
  let __p := io.print(positions.body)

  let __h6 := print_section("GET /risk")
  let risk := srv.get_risk(db, get_ctx())
  let __r := io.print(risk.body)

  let __h7 := print_section("GET /audit  (agent + trade trail events)")
  let audit := srv.get_audit(log, get_ctx())
  io.print(audit.body)
}

# ---- Entry point ----------------------------------------------------
fn main() -> [sql, time, io, fs_write, concurrent, net, crypto, random, fs_read] Unit {
  match conn.connect_sqlite(":memory:") {
    Err(e) => io.print("db error: " + dbe.message(e)),
    Ok(db) => match trail_log.open_memory() {
      Err(msg) => io.print("trail error: " + msg),
      Ok(log) => run_demo(db, log),
    },
  }
}

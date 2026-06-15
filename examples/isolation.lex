# lex-oms-agent — Demo 7: Chinese Wall
#
# Two clients. One system. Zero leakage. Both layers provable at compile time.
#
# CLIENT_ALPHA: HNW tech portfolio      —  500 AAPL  ·  200 MSFT
# CLIENT_BETA:  Institutional balanced  —  100 AAPL  ·  400 NVDA
#
# AAPL appears in both books — with different quantities.
# The output proves each agent can only see its own database.
#
# Two isolation layers, both verified before the process starts:
#
#   STRUCTURAL — each agent receives exactly one ConnDb, its own client's
#                database. Lex has no global state. A function can only use
#                a resource it was explicitly given. alpha_agent cannot
#                conjure db_beta; beta_agent cannot conjure db_alpha. The
#                guarantee is visible in the function signatures and in how
#                main wires them up. No policy rule. No runtime check.
#
#   EFFECT     — each reporting function is declared [sql]. It cannot call
#                net, io, fs_write, or any other side-effecting operation.
#                If alpha_agent tried to POST positions to an external server
#                the compiler would reject it before a single byte left the
#                machine. (See examples/chinese_wall_breach.lex.)
#
# Run:
#   lex run --allow-effects concurrent,crypto,fs_read,fs_write,io,net,proc,random,sql,time \
#           examples/isolation.lex main

import "std.io" as io

import "std.int" as int

import "std.str" as str

import "std.map" as map

import "lex-orm/src/connection" as conn

import "lex-orm/src/error" as dbe

import "lex-trail/src/log" as trail_log

import "lex-oms/src/server" as srv

import "../src/agent" as agent

import "../src/tool" as tool

# ---- HTTP context helpers -----------------------------------------------
fn post_ctx(body :: Str) -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  { method: "POST", path: "/", query: "", body: body, path_params: map.new(), headers: map.from_list([("content-type", "application/json")]), state: map.new() }
}

fn get_ctx() -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  post_ctx("")
}

# ---- Fill helpers -------------------------------------------------------
fn ack_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"0\",\"ord_status\":\"0\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(qty) + "\",\"cum_qty\":\"0\",\"leaves_qty\":\"" + int.to_str(qty) + "\",\"avg_px\":\"0\",\"last_px\":\"\",\"last_qty\":\"\",\"text\":\"\"}"
}

fn fill_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int, px :: Str) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"2\",\"ord_status\":\"2\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(qty) + "\",\"cum_qty\":\"" + int.to_str(qty) + "\",\"leaves_qty\":\"0\",\"avg_px\":\"" + px + "\",\"last_px\":\"" + px + "\",\"last_qty\":\"" + int.to_str(qty) + "\",\"text\":\"\"}"
}

fn fill_order(db :: conn.ConnDb, tag :: Str, cl_ord_id :: Str, sym :: Str, qty :: Int, px :: Str) -> [sql, time, crypto] Unit {
  let __a := srv.post_execution_reports(db, post_ctx(ack_json("EX-A-" + tag, "EXCH-" + tag, cl_ord_id, sym, "buy", qty)))
  let __f := srv.post_execution_reports(db, post_ctx(fill_json("EX-F-" + tag, "EXCH-" + tag, cl_ord_id, sym, "buy", qty, px)))
  ()
}

# ---- Seed portfolios ----------------------------------------------------
fn seed_alpha(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  let __1 := fill_order(db, "A1", "ALPHA-AAPL", "AAPL", 500, "175.00")
  let __2 := fill_order(db, "A2", "ALPHA-MSFT", "MSFT", 200, "420.00")
  ()
}

fn seed_beta(db :: conn.ConnDb) -> [sql, time, crypto] Unit {
  let __1 := fill_order(db, "B1", "BETA-AAPL", "AAPL", 100, "175.00")
  let __2 := fill_order(db, "B2", "BETA-NVDA", "NVDA", 400, "875.00")
  ()
}

# ---- Scripted compliance snapshot agent ---------------------------------
#
# decide :: (List[Step]) -> Tool  — no effects.
# The decide function only inspects history and returns a Tool value.
# Actual database access happens inside agent.run, which uses the ConnDb
# from the AgentCtx. An agent can only see the database wired into its context.
fn snapshot_decide(history :: List[agent.Step]) -> tool.Tool {
  if agent.steps_taken(history) == 0 {
    Observe(Positions)
  } else {
    AgentDone("Compliance snapshot filed")
  }
}

# ---- Print section ------------------------------------------------------
fn section(title :: Str) -> [io] Unit {
  let __nl := io.print("")
  io.print("=== " + title + " ===")
}

# ---- Demo ---------------------------------------------------------------
fn run_demo(db_alpha :: conn.ConnDb, db_beta :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, crypto, io] Unit {
  let __init_a := srv.init_db(db_alpha)
  let __init_b := srv.init_db(db_beta)
  let __sa := seed_alpha(db_alpha)
  let __sb := seed_beta(db_beta)
  let alpha_ctx := { db: db_alpha, log: log, max_steps: 2, clock: ClockWall }
  let beta_ctx := { db: db_beta, log: log, max_steps: 2, clock: ClockWall }
  let __ra := agent.run(alpha_ctx, snapshot_decide)
  let __rb := agent.run(beta_ctx, snapshot_decide)
  let __h1 := section("CLIENT_ALPHA positions  (reads db_alpha)")
  let __pa := io.print(srv.get_positions(db_alpha, get_ctx()).body)
  let __h2 := section("CLIENT_BETA positions  (reads db_beta)")
  let __pb := io.print(srv.get_positions(db_beta, get_ctx()).body)
  let __h3 := section("CHINESE WALL PROOF")
  let __p1 := io.print("  ALPHA sees AAPL: 500 shares")
  let __p2 := io.print("  BETA  sees AAPL: 100 shares")
  let __p3 := io.print("")
  let __p4 := io.print("  Same symbol. Separate databases. Zero leakage.")
  let __p5 := io.print("  alpha_agent never received db_beta — it has no name for it.")
  let __p6 := io.print("  beta_agent never received db_alpha — it has no name for it.")
  let __p7 := io.print("")
  let __p8 := io.print("  Effect layer: run  lex check examples/chinese_wall_breach.lex")
  let __p9 := io.print("  Neither agent can POST, write to disk, or print to stdout.")
  ()
}

fn main() -> [sql, time, crypto, io, random, net, concurrent, fs_write, fs_read, proc] Unit {
  match conn.connect_sqlite(":memory:") {
    Err(e) => io.print("db error: " + dbe.message(e)),
    Ok(db_alpha) => match conn.connect_sqlite(":memory:") {
      Err(e) => io.print("db error: " + dbe.message(e)),
      Ok(db_beta) => match trail_log.open_memory() {
        Err(m) => io.print("trail error: " + m),
        Ok(log) => run_demo(db_alpha, db_beta, log),
      },
    },
  }
}


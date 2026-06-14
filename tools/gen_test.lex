# Pure tests for the scenario generator's parsing (no network).
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#     tools/gen_test.lex run_all

import "std.io" as io
import "std.list" as list
import "std.int" as int

import "./gen_scenario" as gen

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond { Ok(()) } else { Err(name) }
}

# extract pulls (time=col0, close=col4) from each row of a candle array.
fn t_extract() -> Result[Unit, Str] {
  let body := "[[100,1.0,2.0,3.0,4.5,9.0],[200,1.0,2.0,3.0,5.0,9.0],[300,1.0,2.0,3.0,6.25,9.0]]"
  let pairs := gen.extract(body)
  if list.len(pairs) == 3 {
    match list.head(pairs) {
      None => Err("empty"),
      Some(p) => match p { (t, c) => if t == "100" and c == "4.5" { Ok(()) } else { Err("first pair = (" + t + "," + c + ")") } },
    }
  } else {
    Err("expected 3 rows, got " + int.to_str(list.len(pairs)))
  }
}

# round2 caps precision to 2dp (and gives integers a decimal point).
fn t_round2() -> Result[Unit, Str] {
  if gen.round2("298.8699951171875") == "298.87" {
    check("integer token", gen.round2("64334") == "64334.00")
  } else { Err("round2(298.86999…) = " + gen.round2("298.8699951171875")) }
}

# between extracts the text inside markers (Yahoo close/timestamp arrays).
fn t_between() -> Result[Unit, Str] {
  let body := "{\"x\":1,\"close\":[1.2,3.4,5.6],\"adjclose\":[9.9]}"
  let got := gen.between(body, "\"close\":[", "]")
  check("between", got == "1.2,3.4,5.6")
}

# fill_nulls carries the last good value forward over null/empty tokens.
fn t_fill_nulls() -> Result[Unit, Str] {
  let out := gen.fill_nulls(["1.0", "null", "2.0", "null"])
  check("fill_nulls", gen_join(out) == "1.0,1.0,2.0,2.0")
}

fn gen_join(xs :: List[Str]) -> Str {
  list.fold(xs, "", fn (acc :: Str, x :: Str) -> Str {
    if acc == "" { x } else { acc + "," + x }
  })
}

fn run_all() -> [io] Int {
  let results := [t_extract(), t_round2(), t_between(), t_fill_nulls()]
  let fails := list.fold(results, 0, fn (acc :: Int, r :: Result[Unit, Str]) -> [io] Int {
    match r { Ok(_) => acc, Err(e) => { let __ := io.print("FAIL: " + e) acc + 1 } }
  })
  let __ := io.print("gen tests: " + int.to_str(4 - fails) + "/4 passed")
  fails
}

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

# norm_price gives integer-valued tokens a decimal point so parse_price accepts them.
fn t_norm_price() -> Result[Unit, Str] {
  if gen.norm_price("64334") == "64334.0" {
    check("keeps existing point", gen.norm_price("64242.28") == "64242.28")
  } else {
    Err("norm_price(64334) = " + gen.norm_price("64334"))
  }
}

fn run_all() -> [io] Int {
  let results := [t_extract(), t_norm_price()]
  let fails := list.fold(results, 0, fn (acc :: Int, r :: Result[Unit, Str]) -> [io] Int {
    match r { Ok(_) => acc, Err(e) => { let __ := io.print("FAIL: " + e) acc + 1 } }
  })
  let __ := io.print("gen tests: " + int.to_str(2 - fails) + "/2 passed")
  fails
}

# lex-arena — scenario generator from real market data
#
# Turns real historical prices into a FROZEN arena scenario. Verification
# requires the market to be identical for every replay, so we never fetch
# live during a run — we snapshot real history here, once, into a scenario
# file whose `scenario_id` then pins it forever.
#
# Source: Coinbase Exchange candles — free, no API key. Returns a plain
# JSON array of arrays [time, low, high, open, close, volume]. We don't
# JSON-decode it (Lex's typed parser can't handle heterogeneous arrays);
# the rows are clean comma-separated numbers, and the scenario format wants
# price *strings* anyway, so we extract the close column textually and keep
# the original decimal tokens.
#
# Run (products are Coinbase product ids; granularity in seconds):
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#     tools/gen_scenario.lex gen \
#     '"BTC-USD,ETH-USD,SOL-USD"' '"3600"' '"48"' '"crypto-48h"' '"scenarios/crypto-48h.json"'

import "std.io" as io
import "std.str" as str
import "std.int" as int
import "std.list" as list

import "lex-cli/api" as api

import "../src/arena/scenario" as scenario

# ---- small helpers (std.list has no nth/take) ------------------------

fn nth_str(xs :: List[Str], i :: Int) -> Str {
  list.fold(list.enumerate(xs), "", fn (acc :: Str, p :: (Int, Str)) -> Str {
    match p { (j, v) => if j == i { v } else { acc } }
  })
}

fn take_strs(xs :: List[Str], n :: Int) -> List[Str] {
  let kept := list.filter(list.enumerate(xs), fn (p :: (Int, Str)) -> Bool {
    match p { (j, _v) => j < n }
  })
  list.map(kept, fn (p :: (Int, Str)) -> Str { match p { (_j, v) => v } })
}

# Ensure a token parses as a decimal price (pos.parse_price wants a point).
fn norm_price(c :: Str) -> Str {
  if str.contains(c, ".") { c } else { c + ".0" }
}

# ---- fetch one product ----------------------------------------------

type ProdData = { symbol :: Str, closes :: List[Str], first_time_ms :: Int }

# Split "[[a,b,c,d,e,f],[...]]" into rows and pull (time=col0, close=col4)
# from each. Brackets are stripped per row; numbers contain no commas or
# brackets, so a plain comma split is safe.
fn extract(body :: Str) -> List[(Str, Str)] {
  let rows := str.split(body, "],[")
  list.map(rows, fn (raw :: Str) -> (Str, Str) {
    let clean := str.replace(str.replace(raw, "[", ""), "]", "")
    let cols := str.split(clean, ",")
    (nth_str(cols, 0), nth_str(cols, 4))
  })
}

fn fetch_product(product :: Str, gran :: Int, limit :: Int) -> [net, env] Result[ProdData, Str] {
  let res := api.get_json("https://api.exchange.coinbase.com", "/products/" + product + "/candles?granularity=" + int.to_str(gran), "")
  if res.ok {
    # Coinbase returns newest-first; take the most recent `limit`, then
    # reverse to chronological so step n advances in time.
    let pairs := list.reverse(take_pairs(extract(res.body), limit))
    let closes := list.map(pairs, fn (p :: (Str, Str)) -> Str { match p { (_t, c) => norm_price(c) } })
    let first_t := match list.head(pairs) {
      None => 0,
      Some(p) => match p { (t, _c) => match str.to_int(t) { None => 0, Some(n) => n } },
    }
    Ok({ symbol: product, closes: closes, first_time_ms: first_t * 1000 })
  } else {
    Err("http " + int.to_str(res.status) + " for " + product)
  }
}

fn take_pairs(xs :: List[(Str, Str)], n :: Int) -> List[(Str, Str)] {
  let kept := list.filter(list.enumerate(xs), fn (p :: (Int, (Str, Str))) -> Bool {
    match p { (j, _v) => j < n }
  })
  list.map(kept, fn (p :: (Int, (Str, Str))) -> (Str, Str) { match p { (_j, v) => v } })
}

# ---- collect Results, short-circuiting on the first error ------------

fn collect(rs :: List[Result[ProdData, Str]]) -> Result[List[ProdData], Str] {
  list.fold(rs, Ok([]), fn (acc :: Result[List[ProdData], Str], r :: Result[ProdData, Str]) -> Result[List[ProdData], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(xs) => match r {
        Err(e) => Err(e),
        Ok(d) => Ok(list.concat(xs, [d])),
      },
    }
  })
}

fn min_count(ds :: List[ProdData]) -> Int {
  list.fold(ds, 1000000000, fn (acc :: Int, d :: ProdData) -> Int {
    let n := list.len(d.closes)
    if n < acc { n } else { acc }
  })
}

fn instrument_json(d :: ProdData, n :: Int) -> Str {
  let prices := str.join(take_strs(d.closes, n), ",")
  "{\"symbol\":\"" + d.symbol + "\",\"prices\":\"" + prices + "\"}"
}

# ---- entry ----------------------------------------------------------

fn gen(products_csv :: Str, gran_str :: Str, limit_str :: Str, name :: Str, out_path :: Str) -> [net, io, env] Int {
  let gran := match str.to_int(gran_str) { None => 3600, Some(g) => g }
  let limit := match str.to_int(limit_str) { None => 100, Some(l) => l }
  let products := list.map(str.split(products_csv, ","), fn (s :: Str) -> Str { str.trim(s) })

  let fetched := list.map(products, fn (p :: Str) -> [net, env] Result[ProdData, Str] {
    fetch_product(p, gran, limit)
  })

  match collect(fetched) {
    Err(e) => { let __ := io.print("{\"error\":\"" + e + "\"}") 1 },
    Ok(ds) => {
      let n := min_count(ds)
      let start := match list.head(ds) { None => 0, Some(d) => d.first_time_ms }
      let instruments := str.join(list.map(ds, fn (d :: ProdData) -> Str { instrument_json(d, n) }), ",")
      let scenario_json := "{\"version\":\"2\",\"name\":\"" + name
        + "\",\"seed\":0,\"episode_start_ms\":" + int.to_str(start)
        + ",\"tick_ms\":" + int.to_str(gran * 1000)
        + ",\"max_steps\":" + int.to_str(n)
        + ",\"instruments\":[" + instruments + "]}"
      match io.write(out_path, scenario_json) {
        Err(e) => { let __ := io.print("{\"error\":\"write failed: " + e + "\"}") 1 },
        Ok(_) => match scenario.from_json(scenario_json) {
          Err(e) => { let __ := io.print("{\"error\":\"generated scenario invalid: " + e + "\"}") 1 },
          Ok(sc) => {
            let __p := io.print("{\"out\":\"" + out_path + "\",\"name\":\"" + name
              + "\",\"instruments\":" + int.to_str(list.len(ds))
              + ",\"steps\":" + int.to_str(n)
              + ",\"scenario_id\":\"" + scenario.scenario_id(sc) + "\"}")
            0
          },
        },
      }
    },
  }
}

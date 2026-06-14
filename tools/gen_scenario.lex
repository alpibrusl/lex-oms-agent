# lex-arena — scenario generator from real market data
#
# Turns real historical prices into a FROZEN arena scenario. Verification
# requires the market to be identical for every replay, so we never fetch
# live during a run — we snapshot real history here, once, into a scenario
# file whose `scenario_id` then pins it forever.
#
# Sources (both free, no API key):
#   gen        — Coinbase Exchange candles (crypto): array of arrays
#                [time, low, high, open, close, volume].
#   gen_stocks — Yahoo Finance chart API (stocks): parallel timestamp[]/close[].
# We don't JSON-decode the arrays (Lex's typed parser can't handle heterogeneous
# arrays); we extract the close column textually and round to 2dp. See README.md.
#
# Run (products are Coinbase product ids; granularity in seconds):
#   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
#     tools/gen_scenario.lex gen \
#     '"BTC-USD,ETH-USD,SOL-USD"' '"3600"' '"48"' '"crypto-48h"' '"scenarios/crypto-48h.json"'

import "std.io" as io
import "std.str" as str
import "std.int" as int
import "std.list" as list
import "std.float" as float

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

# Round a price token to 2 decimals. Also normalizes integer-valued tokens
# (which need a decimal point) and — crucially — caps precision so the
# Decimal coefficient stays small: full-precision source values (e.g. Yahoo's
# 298.8699951171875) otherwise overflow decimal math during scoring.
# Assets priced well under $0.01 would lose all precision here; fine for the
# equities / major crypto in scope.
fn round2(c :: Str) -> Str {
  match str.to_float(c) {
    None => "0.00",
    Some(f) => {
      let cents := float.to_int(f * 100.0 + 0.5)
      let dollars := cents / 100
      let rem := cents - dollars * 100
      let frac := if rem < 10 { "0" + int.to_str(rem) } else { int.to_str(rem) }
      int.to_str(dollars) + "." + frac
    },
  }
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
    let closes := list.map(pairs, fn (p :: (Str, Str)) -> Str { match p { (_t, c) => round2(c) } })
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

# ---- shared emit ----------------------------------------------------
# Build the v2 scenario JSON from fetched products, write it, then parse it
# back to confirm it's well-formed and print the frozen scenario_id.

fn emit(ds :: List[ProdData], name :: Str, tick_ms :: Int, out_path :: Str) -> [io] Int {
  let n := min_count(ds)
  let start := match list.head(ds) { None => 0, Some(d) => d.first_time_ms }
  let instruments := str.join(list.map(ds, fn (d :: ProdData) -> Str { instrument_json(d, n) }), ",")
  let scenario_json := "{\"version\":\"2\",\"name\":\"" + name
    + "\",\"seed\":0,\"episode_start_ms\":" + int.to_str(start)
    + ",\"tick_ms\":" + int.to_str(tick_ms)
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
}

# ---- crypto entry (Coinbase) ----------------------------------------

fn gen(products_csv :: Str, gran_str :: Str, limit_str :: Str, name :: Str, out_path :: Str) -> [net, io, env] Int {
  let gran := match str.to_int(gran_str) { None => 3600, Some(g) => g }
  let limit := match str.to_int(limit_str) { None => 100, Some(l) => l }
  let products := list.map(str.split(products_csv, ","), fn (s :: Str) -> Str { str.trim(s) })
  let fetched := list.map(products, fn (p :: Str) -> [net, env] Result[ProdData, Str] {
    fetch_product(p, gran, limit)
  })
  match collect(fetched) {
    Err(e) => { let __ := io.print("{\"error\":\"" + e + "\"}") 1 },
    Ok(ds) => emit(ds, name, gran * 1000, out_path),
  }
}

# ---- stock entry (Yahoo Finance) ------------------------------------
# Yahoo's chart API returns an object with parallel `timestamp[]` and
# `indicators.quote[0].close[]` arrays. We extract the close array textually
# (same reason as crypto), carry forward nulls (holidays / missing bars),
# and treat each bar as one step.

fn between(s :: Str, a :: Str, b :: Str) -> Str {
  let after := nth_str(str.split(s, a), 1)
  if str.is_empty(after) { "" } else { nth_str(str.split(after, b), 0) }
}

# Carry forward the last good value over nulls so the series stays aligned.
fn fill_nulls(tokens :: List[Str]) -> List[Str] {
  let r := list.fold(tokens, { last: "0.0", out: [] }, fn (st :: { last :: Str, out :: List[Str] }, tok :: Str) -> { last :: Str, out :: List[Str] } {
    let t := str.trim(tok)
    let v := if t == "null" or str.is_empty(t) { st.last } else { t }
    { last: v, out: list.concat(st.out, [v]) }
  })
  r.out
}

fn interval_ms(iv :: Str) -> Int {
  if iv == "1d" { 86400000 }
  else { if iv == "1h" { 3600000 }
  else { if iv == "1wk" { 604800000 }
  else { if iv == "1m" { 60000 }
  else { 86400000 } } } }
}

fn fetch_stock(symbol :: Str, range :: Str, interval :: Str) -> [net, env] Result[ProdData, Str] {
  let res := api.get_json("https://query1.finance.yahoo.com", "/v8/finance/chart/" + symbol + "?range=" + range + "&interval=" + interval, "")
  if res.ok {
    let closes_raw := between(res.body, "\"close\":[", "]")
    if str.is_empty(closes_raw) {
      Err("no close data for " + symbol)
    } else {
      let toks := list.map(str.split(closes_raw, ","), fn (s :: Str) -> Str { str.trim(s) })
      let closes := list.map(fill_nulls(toks), fn (c :: Str) -> Str { round2(c) })
      let ts_raw := between(res.body, "\"timestamp\":[", "]")
      let first_t := match list.head(str.split(ts_raw, ",")) {
        None => 0,
        Some(t) => match str.to_int(str.trim(t)) { None => 0, Some(n) => n },
      }
      # Yahoo returns chronological order already.
      Ok({ symbol: symbol, closes: closes, first_time_ms: first_t * 1000 })
    }
  } else {
    Err("http " + int.to_str(res.status) + " for " + symbol)
  }
}

fn gen_stocks(symbols_csv :: Str, range :: Str, interval :: Str, name :: Str, out_path :: Str) -> [net, io, env] Int {
  let symbols := list.map(str.split(symbols_csv, ","), fn (s :: Str) -> Str { str.trim(s) })
  let fetched := list.map(symbols, fn (s :: Str) -> [net, env] Result[ProdData, Str] {
    fetch_stock(s, range, interval)
  })
  match collect(fetched) {
    Err(e) => { let __ := io.print("{\"error\":\"" + e + "\"}") 1 },
    Ok(ds) => emit(ds, name, interval_ms(interval), out_path),
  }
}

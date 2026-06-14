# Arena tooling

## `gen_scenario.lex` — real-market scenario generator

Turns **real historical prices** into a frozen Arena scenario.

### Why it's offline (not a live feed)
Verification replays an agent's decisions against the *exact same* market, so the
data must be identical for every replay, forever. We therefore snapshot real
history **once**, write it into a scenario file, and let the existing
`scenario_id` hash pin it. Agents never touch a live feed during a run.

### Sources (both free, no API key)

**Crypto — Coinbase Exchange candles** (`gen`).
Returns `[time, low, high, open, close, volume]` per bar; we extract the **close**
column textually (Lex's typed JSON parser can't handle heterogeneous arrays, and
the scenario format wants price strings anyway).
```
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
  tools/gen_scenario.lex gen \
  '<products>' '<granularity_seconds>' '<bars>' '<name>' '<out_path>'
```
Example — 48 hourly bars of BTC/ETH/SOL:
```
... gen '"BTC-USD,ETH-USD,SOL-USD"' '"3600"' '"48"' '"crypto-48h"' '"scenarios/crypto-48h.json"'
```
Granularity must be a Coinbase value (60, 300, 900, 3600, 21600, 86400); max 300
bars/request. Agents trade by product id (`BTC-USD`, …).

**Stocks — Yahoo Finance chart API** (`gen_stocks`).
Returns parallel `timestamp[]` / `close[]` arrays; we extract `close` textually and
**carry nulls forward** (holidays / missing bars). Each bar = one step.
```
... gen_stocks '<symbols>' '<range>' '<interval>' '<name>' '<out_path>'
```
Example — ~22 daily bars of AAPL/MSFT/NVDA:
```
... gen_stocks '"AAPL,MSFT,NVDA"' '"1mo"' '"1d"' '"stocks-1mo"' '"scenarios/stocks-1mo.json"'
```
`range`: `5d`/`1mo`/`3mo`/`6mo`/`1y`/… `interval`: `1d`/`1h`/`1wk`/`1m`. Yahoo's
endpoint is unofficial (no key, ToS-gray) — fine for authoring, don't depend on it
in CI.

Prices from either source are rounded to **2 decimals** (`round2`) — full source
precision overflows Lex's `Decimal` during scoring. Sub-cent assets would lose
precision; fine for equities / major crypto.

Pre-generated examples: `scenarios/crypto-48h.json`, `scenarios/stocks-1mo.json`.
Products are aligned to the shortest series. Regenerate any time; the `scenario_id`
changes with the data — each snapshot is its own immutable episode.

### Tests
`lex run --allow-effects … tools/gen_test.lex run_all` — pure parsing tests, no network.

### Roadmap
- Realistic fills: spread + slippage — issue #20
- Transaction costs — issue #21

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

### Execution cost model (optional)
A scenario may carry a `cost` block; without one, fills are frictionless (the
original behavior, and the generator's default output). When present and non-zero
it's folded into the `scenario_id`, so cost-bearing episodes are pinned just like
the prices.
```json
"cost": { "spread_bps": 5, "impact_bps": 3, "lot": 1, "fee_bps": 10, "fee_per_unit_cents": 0, "max_fill": 0 }
```
- `spread_bps` — half-spread crossed on every fill (buys up, sells down).
- `impact_bps` / `lot` — linear market impact: `impact_bps` of extra slippage per
  `lot` shares of the *filled* size, so a large order's average fill degrades with size.
- `fee_bps` — commission as basis points of traded notional.
- `fee_per_unit_cents` — per-share/contract commission, in cents.
- `max_fill` — per-order liquidity cap (shares); size beyond it is unfilled and
  scores nothing. `0` = unlimited.

Effective fill = `mid × (1 ± (spread_bps + impact_bps·filled/lot) / 10000)`; commission
per fill = `notional · fee_bps/10000 + filled · fee_per_unit_cents/100`; `filled =
min(qty, max_fill)`. **P&L in the verdict is net of commissions**, with the total
reported separately as `fees`. See `src/arena/fills.lex`. Examples:
`scenarios/crypto-48h-costs.json` (spread+impact), `scenarios/crypto-48h-fees.json`
(+ commission).

**Generating cost-bearing scenarios:** set `ARENA_COST` to a cost JSON object and the
generator splices it in:
```
ARENA_COST='{"spread_bps":5,"impact_bps":3,"lot":1,"fee_bps":10,"fee_per_unit_cents":0,"max_fill":0}' \
  lex run … tools/gen_scenario.lex gen 'BTC-USD,ETH-USD' 3600 48 crypto-real out.json
```
Older cost blocks missing newer fields (fees, then `max_fill`) still parse — the
missing fields default to zero; a scenario with no `cost` block stays frictionless.

### Tests
`lex run --allow-effects … tools/gen_test.lex run_all` — pure parsing tests, no network.
`lex run --allow-effects … tests/test_arena.lex arena_main` — spread, slippage, fee + partial-fill tests.

### Roadmap
- Surface `fees` as a leaderboard column (loom-cloud) — issue #32

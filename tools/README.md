# Arena tooling

## `gen_scenario.lex` — real-market scenario generator

Turns **real historical prices** into a frozen Arena scenario.

### Why it's offline (not a live feed)
Verification replays an agent's decisions against the *exact same* market, so the
data must be identical for every replay, forever. We therefore snapshot real
history **once**, write it into a scenario file, and let the existing
`scenario_id` hash pin it. Agents never touch a live feed during a run.

### Source
[Coinbase Exchange candles](https://docs.cdp.coinbase.com/exchange/reference/exchangerestapi_getproductcandles)
— free, **no API key**. Returns `[time, low, high, open, close, volume]` per bar.
We extract the **close** column textually (Lex's typed JSON parser can't handle
heterogeneous arrays, and the scenario format wants price strings anyway).

### Usage
```
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
  tools/gen_scenario.lex gen \
  '<products>' '<granularity_seconds>' '<bars>' '<name>' '<out_path>'
```
Example — 48 hourly bars of BTC/ETH/SOL:
```
... gen '"BTC-USD,ETH-USD,SOL-USD"' '"3600"' '"48"' '"crypto-48h"' '"scenarios/crypto-48h.json"'
```
Granularity must be a Coinbase-supported value (60, 300, 900, 3600, 21600, 86400);
max 300 bars per request. Products are aligned to the shortest series. The agent
trades these symbols by their product id (`BTC-USD`, …).

A pre-generated example lives at `scenarios/crypto-48h.json`. Regenerate any time;
the `scenario_id` changes with the data, which is the point — each snapshot is its
own immutable episode.

### Tests
`lex run --allow-effects … tools/gen_test.lex run_all` — pure parsing tests, no network.

### Roadmap
- Stock source (Stooq/Yahoo) — issue #19
- Realistic fills: spread + slippage — issue #20
- Transaction costs — issue #21

# lex-oms-agent

LLM-backed autonomous trading agent built on [lex-oms](https://github.com/alpibrusl/lex-oms). An LLM observes the order book, positions, and risk — then submits, cancels, and monitors orders — all via a typed tool loop with a tamper-evident audit trail.

Supports **Anthropic Claude** and **Google Gemini 3.5** (via Vertex AI).

---

## How it works

The agent loop is parameterised over a `decide` function:

```
decide(history) -> (Tool, call_id)
```

Each turn the LLM receives the full conversation history and calls exactly one tool:

| Tool | Args |
|---|---|
| `observe` | `target: blotter \| positions \| risk \| audit` |
| `submit_order` | `cl_ord_id, symbol, side, quantity` |
| `cancel_order` | `cl_ord_id, orig_cl_ord_id, symbol, side` |
| `done` | `reason` |

Every step is logged to a [lex-trail](https://github.com/alpibrusl/lex-trail) audit log after the tool is dispatched. The OMS pre-trade gate (risk limits → FIX conformance) runs on every order before acceptance.

---

## Demos

### Demo 0 — scripted agent (no LLM)

7-step scripted loop: observe blotter → submit 3 orders → observe blotter → observe risk → done. All OMS machinery is real; the LLM is replaced by a hardcoded decision function.

```sh
lex run --allow-effects concurrent,crypto,fs_read,fs_write,io,net,random,sql,time \
        examples/demo.lex main
```

---

### Demo 1 — portfolio rebalancer

Seeds a skewed portfolio (700 AAPL · 150 MSFT · 50 NVDA), then turns the LLM loose to rebalance to equal 300-share weights per symbol. The goal gives no explicit trade instructions — the agent observes positions, computes the target (300 shares each), figures out the three required trades, submits them, and calls `done`.

```sh
# Anthropic
ANTHROPIC_API_KEY=sk-ant-... \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/portfolio_rebalancer.lex main

# Vertex AI (Gemini 3.5 Flash)
LLM_PROVIDER=vertex \
VERTEX_PROJECT=my-project \
VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/portfolio_rebalancer.lex main
```

Sample output (Gemini — cl_ord_ids and step count vary by run):
```
=== PHASE 1 — Seed skewed portfolio (scripted) ===
Seeded: 700 AAPL  150 MSFT  50 NVDA

=== PHASE 2 — LLM rebalancer  [provider=vertex  model=gemini-3.5-flash] ===
GoalMet: All three rebalancing orders have been accepted by the OMS.

=== Blotter ===
<llm-chosen-id>   AAPL sell 400   PendingNew
<llm-chosen-id>   MSFT buy  150   PendingNew
<llm-chosen-id>   NVDA buy  250   PendingNew
```

---

### Demo 2 — LLM risk monitor

Seeds a base portfolio (300 AAPL · 50 MSFT · 50 NVDA), then a scripted "rogue trader" doubles down on AAPL (+300), pushing it to 600 shares — above the 500-share policy limit. The LLM risk monitor observes positions and risk, identifies the breach, sells 200 AAPL to bring it under the limit, and improves diversification by buying MSFT and NVDA.

```sh
# Anthropic
ANTHROPIC_API_KEY=sk-ant-... \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/risk_monitor.lex main

# Vertex AI
LLM_PROVIDER=vertex \
VERTEX_PROJECT=my-project \
VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/risk_monitor.lex main
```

---

### Demo 3 — A2A trading agent server

Exposes the trading agent as a [Google Agent2Agent (A2A)](https://google.github.io/A2A/) service over JSON-RPC 2.0. Any A2A-compatible client sends a natural-language trading goal; the server runs the full agent loop and returns a summary plus blotter, positions, and risk as artifacts.

```sh
ANTHROPIC_API_KEY=sk-ant-... \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/a2a_agent.lex main
# Listening on :4041
```

Discover the agent card:
```sh
curl http://localhost:4041/.well-known/agent.json
```

Submit a trading goal:
```sh
curl -X POST http://localhost:4041/ \
  -H 'content-type: application/json' \
  -d '{
    "jsonrpc": "2.0", "id": 1, "method": "tasks/send",
    "params": {
      "id": "t_1", "contextId": "ctx_1", "skill": "execute_trade_goal",
      "message": {
        "kind": "message", "messageId": "m1", "role": "user",
        "parts": [{"type": "text", "text":
          "Buy 100 AAPL and 50 MSFT at market. Call done when both are accepted."
        }]
      }
    }
  }'
```

Response includes:
- `summary` — outcome text from the agent
- `blotter` artifact — all orders and their states
- `positions` artifact — current positions
- `risk` artifact — portfolio Greeks and margin

---

### Demo 4 — adversarial agents

Two LLM agents with opposing mandates act on the same portfolio through the same OMS. Neither is told about the other.

**Setup (scripted):** seed 400 AAPL · 100 MSFT · 100 NVDA, then inject a rogue +200 AAPL fill → positions hit 600 AAPL, above the 500-share policy limit.

**Agent A — Aggressive Trader:** mandate is to concentrate into the biggest holding. Sees 600 AAPL, buys more. Exchange fills are simulated immediately.

**Agent B — Risk Monitor:** mandate is to enforce the 500-share limit. Observes the blotter, cancels the trader's pending buy orders, then sells the excess. Calls done when the breach is resolved.

The audit trail records both agents' full decision chains on the same log.

```sh
# Anthropic
ANTHROPIC_API_KEY=sk-ant-... \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/adversarial.lex main

# Vertex AI
LLM_PROVIDER=vertex \
VERTEX_PROJECT=my-project \
VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/adversarial.lex main
```

---

### Demo 5 — dual-breach compliance monitor

A $112M institutional equity portfolio governed by MiFID II Article 57: no single position may exceed $50,000,000 notional. Two rogue fills bypass the OMS gate and breach both AAPL (+$2.5M) and MSFT (+$2.5M). The **Lex risk engine** computes the exact corrective sell quantities before the LLM runs — the agent submits the pre-computed trades and files a formal dual-breach incident report. Every step is hash-chained in a tamper-evident audit trail.

```sh
# Anthropic
ANTHROPIC_API_KEY=sk-ant-... \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/compliance.lex main

# Vertex AI
LLM_PROVIDER=vertex \
VERTEX_PROJECT=my-project \
VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/compliance.lex main
```

Sample output (Gemini 3.5 Flash):
```
=== PORTFOLIO — Seed positions (all within limit) ===
  Policy: MiFID II Art. 57  |  Limit: $50,000,000 max notional per name
  AAPL: 200,000 shares x $175 = $35,000,000
  MSFT:  80,000 shares x $420 = $33,600,000
  NVDA:  50,000 shares x $875 = $43,750,000
  NAV: $112,350,000

=== INCIDENT — Unauthorised fills injected (bypass OMS gate) ===
  ROGUE-AAPL  +100,000 shares → injected via execution report
  ROGUE-MSFT   +45,000 shares → injected via execution report
  AAPL: 300,000 shares x $175 = $52,500,000  *** BREACH $2,500,000 over limit ***
  MSFT: 125,000 shares x $420 = $52,500,000  *** BREACH $2,500,000 over limit ***

=== RISK ENGINE — corrective quantities (deterministic) ===
  AAPL  excess $2,500,000  →  sell 14,286 shares  (restored to $49,999,950)
  MSFT  excess $2,500,000  →  sell  5,953 shares  (restored to $49,999,740)
  No LLM involved in this computation.

=== COMPLIANCE INCIDENT REPORT ===
MiFID II Article 57 Incident Report:
1. Breaches: AAPL $52,500,000 (+$2,500,000)  MSFT $52,500,000 (+$2,500,000)
2. Corrective sells: AAPL 14,286 shares  MSFT 5,953 shares
3. Positions restored within limit.
```

---

### Demo 6 — live enforcement (momentum trader vs compliance monitor)

The flagship demo. Three guarantees that no Python framework can offer:

1. **Effect isolation** — the compliance monitor is declared `[sql, llm]`. It cannot touch the network or filesystem. Not by policy. Not by runtime monitoring. Proven at compile time. (See `examples/bad_agent.lex`.)

2. **Live enforcement** — the compliance monitor intercepts the momentum trader's pending buy before the exchange sees it. The OMS is the single enforcement point. Both agents share it.

3. **Tamper-evident chain** — every decision is content-addressed and hash-chained. No party can rewrite history. Regulators verify the root hash independently.

**Timeline:**
1. Seed: AAPL $35M · MSFT $33.6M · NVDA $43.75M (NAV $112,350,000)
2. Two rogue fills bypass the OMS gate (injected via execution reports): AAPL +100k → $52.5M breach, MSFT +45k → $52.5M breach
3. **Lex risk engine** (deterministic, no LLM): AAPL corrective sell = 14,286 shares · MSFT = 5,953 shares
4. **Momentum Trader (LLM):** AAPL buy → blocked ($52.5M cap), MSFT buy → blocked ($52.5M cap), NVDA buy → accepted → **PendingNew**
5. **Compliance Monitor (LLM):** cancels trader's NVDA buy before exchange fills it → sells 14,286 AAPL → sells 5,953 MSFT → files formal incident report

```sh
# Anthropic
ANTHROPIC_API_KEY=sk-ant-... \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/enforcement.lex main

# Vertex AI
LLM_PROVIDER=vertex \
VERTEX_PROJECT=my-project \
VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/enforcement.lex main
```

Sample output (Gemini 3.5 Flash):
```
=== PORTFOLIO  —  seed positions, all within limit ===
  Policy: MiFID II Art. 57  |  Limit: $50,000,000 max notional per name
  AAPL:  200,000 shares  x  $175  =  $35,000,000
  MSFT:   80,000 shares  x  $420  =  $33,600,000
  NVDA:   50,000 shares  x  $875  =  $43,750,000  NAV: $112,350,000

=== INCIDENT  —  two rogue fills bypass OMS gate ===
  AAPL: 300,000 x $175 = $52,500,000  *** BREACH $2,500,000 over limit ***
  MSFT: 125,000 x $420 = $52,500,000  *** BREACH $2,500,000 over limit ***

=== RISK ENGINE  —  corrective quantities (deterministic) ===
  AAPL  excess $2,500,000  →  sell 14,286 shares
  MSFT  excess $2,500,000  →  sell  5,953 shares
  No LLM involved in this computation.

=== AGENT A  —  Momentum Trader  [vertex / gemini-3.5-flash] ===
  done: AAPL blocked, MSFT blocked, NVDA buy 5,000 accepted — PendingNew.
  NOTE: exchange fills NOT applied — the buy is PendingNew in the OMS blotter.

=== AGENT B  —  Compliance Monitor  [vertex / gemini-3.5-flash] ===

=== COMPLIANCE INCIDENT REPORT ===
1. Breaches: AAPL $52,500,000 (+$2,500,000)  MSFT $52,500,000 (+$2,500,000)
2. Orders cancelled: NVDA buy 5,000 (PendingNew → PendingCancel — never reached exchange)
3. Corrective sells: AAPL 14,286 shares  MSFT 5,953 shares
4. Positions restored within MiFID II Art. 57 limit.
```

---

### Effect isolation proof — `bad_agent.lex`

This file intentionally does not compile. A compliance agent declared `[sql]` — allowed to read the database and nothing else — tries to call `net.post`. The compiler rejects it:

```sh
lex check examples/bad_agent.lex
# error: effect `net` not declared
```

Not by a policy check at runtime. Not by code review. By the type system, before a single byte leaves the machine. A prompt injection cannot make a `[sql]` function call `[net]`. The guarantee is structural.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `LLM_PROVIDER` | `anthropic` | `anthropic` or `vertex` |
| `ANTHROPIC_API_KEY` | — | Anthropic API key |
| `ANTHROPIC_MODEL` | `claude-haiku-4-5-20251001` | Any Claude model ID |
| `VERTEX_PROJECT` | — | GCP project ID |
| `VERTEX_ACCESS_TOKEN` | — | OAuth2 bearer token (`gcloud auth print-access-token`) |
| `VERTEX_API_KEY` | — | Alternative to `VERTEX_ACCESS_TOKEN` |
| `VERTEX_LOCATION` | `eu` | Multi-region (`eu`, `us`, `global`) or regional (`europe-west1`, …) |
| `VERTEX_MODEL` | `gemini-3.5-flash` | Any Gemini model available on Vertex AI |

---

## Install

```toml
# lex.toml
[dependencies]
"lex-oms-agent" = { git = "https://github.com/alpibrusl/lex-oms-agent" }
```

---

## Stack

| Package | Role |
|---|---|
| [lex-oms](https://github.com/alpibrusl/lex-oms) | HTTP OMS — orders, execution reports, positions, risk |
| [lex-llm](https://github.com/alpibrusl/lex-llm) | Provider abstraction (Anthropic, Vertex AI, OpenAI, Ollama) |
| [lex-trail](https://github.com/alpibrusl/lex-trail) | Content-addressed attestation log |
| [lex-agent](https://github.com/alpibrusl/lex-agent) | A2A server + agent card |
| [lex-spec](https://github.com/alpibrusl/lex-spec) | Spec-gated capability preconditions |
| [lex-schema](https://github.com/alpibrusl/lex-schema) | Schema + JSON validation |

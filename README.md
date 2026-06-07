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

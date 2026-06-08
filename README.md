# lex-oms-agent

LLM-backed autonomous trading agents for Lex with three compile-time guarantees no Python framework can match.

---

## Three guarantees

### 1. Effect isolation

Every agent function declares its effects in its type signature. A compliance monitor declared `[sql]` cannot call the network. Not by a firewall rule. Not by a runtime monitor. Not by code review. The type checker proves it before the process starts.

```sh
lex check examples/chinese_wall_breach.lex
# error: effect `net` not declared
```

### 2. Deterministic computation

LLMs make arithmetic errors. Gemini 3.5 Flash computed 80,000 × $420 = $56,000,000 (correct: $33,600,000) in a live test. Every number the agent acts on is computed in Lex — exact `Decimal`, no floating point — and passed to the LLM as a pre-verified fact. The LLM executes decisions; Lex owns the math.

### 3. Tamper-evident audit trail

Every decision is content-addressed and hash-chained via [lex-trail](https://github.com/alpibrusl/lex-trail). The root hash is independently verifiable — no party can rewrite history after the fact, including the infrastructure operator. Regulators verify without trusting your logs.

---

## Demos

### Demo 0 — scripted agent (no LLM)

7-step scripted loop: observe → submit 3 orders → observe → risk → done. All OMS machinery is real.

```sh
lex run --allow-effects concurrent,crypto,fs_read,fs_write,io,net,random,sql,time \
        examples/demo.lex main
```

---

### Demo 1 — portfolio rebalancer

Seeds a skewed portfolio (700 AAPL · 150 MSFT · 50 NVDA). LLM rebalances to equal 300-share weights with no explicit instructions — it observes positions, computes the required trades, and submits them.

```sh
ANTHROPIC_API_KEY=sk-ant-... \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/portfolio_rebalancer.lex main
```

---

### Demo 2 — LLM risk monitor

Rogue trader doubles down on AAPL (+300 shares, above the 500-share limit). LLM risk monitor observes the breach, sells the excess, improves diversification.

---

### Demo 3 — A2A trading agent server

Exposes the agent as a [Google A2A](https://google.github.io/A2A/) JSON-RPC service. Any A2A-compatible client sends a natural-language trading goal; the server runs the full agent loop.

```sh
ANTHROPIC_API_KEY=sk-ant-... \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/a2a_agent.lex main
# Listening on :4041  — GET /.well-known/agent.json for the agent card
```

---

### Demo 4 — adversarial agents

Two LLM agents with opposing mandates share the same OMS. Neither knows about the other. The trader concentrates into AAPL. The monitor enforces the 500-share limit. The audit trail records both decision chains.

---

### Demo 5 — dual-breach compliance (MiFID II Art. 57)

$112M institutional portfolio. Two rogue fills bypass the OMS gate. **Lex** computes the corrective sell quantities (ceiling division, no LLM arithmetic). Compliance agent submits pre-computed trades and files a formal dual-breach incident report.

```sh
ANTHROPIC_API_KEY=sk-ant-... \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/compliance.lex main
```

---

### Demo 6 — live enforcement

The flagship demo. $112M portfolio, three phases:

1. **Risk engine (Lex):** computes corrective sells for AAPL and MSFT breaches — deterministic, no LLM involved
2. **Momentum Trader (LLM):** AAPL blocked ($52.5M cap), MSFT blocked ($52.5M cap), NVDA buy accepted → `PendingNew`
3. **Compliance Monitor (LLM):** cancels NVDA buy before exchange sees it, submits corrective sells, files MiFID II incident report

```sh
ANTHROPIC_API_KEY=sk-ant-... \
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/enforcement.lex main
```

```
=== AGENT A  —  Momentum Trader ===
done: AAPL blocked, MSFT blocked, NVDA buy 5,000 accepted — PendingNew.

=== AGENT B  —  Compliance Monitor ===
1. Cancelled: NVDA buy (PendingNew → PendingCancel — never reached exchange)
2. Sold: AAPL 14,286 shares  (restored to $49,999,950)
3. Sold: MSFT  5,953 shares  (restored to $49,999,740)
```

---

### Demo 7 — Chinese wall

**CLIENT_ALPHA** (500 AAPL · 200 MSFT) and **CLIENT_BETA** (100 AAPL · 400 NVDA) share the same OMS. Neither agent can see the other's data. Two independent isolation layers, both compile-time:

- **Structural:** each agent's context holds only its own `ConnDb`. In Lex there is no global state. `db_beta` does not exist as a variable inside the alpha agent's scope.
- **Effect:** each reporting function is declared `[sql]`. It cannot call `[net]`, `[io]`, or `[fs_write]`.

```sh
lex run --allow-effects concurrent,crypto,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        examples/isolation.lex main
```

```
=== CLIENT_ALPHA positions  (reads db_alpha) ===
[{"symbol":"AAPL","qty":500,...},{"symbol":"MSFT","qty":200,...}]

=== CLIENT_BETA positions  (reads db_beta) ===
[{"symbol":"AAPL","qty":100,...},{"symbol":"NVDA","qty":400,...}]

=== CHINESE WALL PROOF ===
  ALPHA sees AAPL: 500 shares
  BETA  sees AAPL: 100 shares
  Same symbol. Separate databases. Zero leakage.
```

```sh
# Effect layer — see what the compiler rejects
lex check examples/chinese_wall_breach.lex
# error: effect `net` not declared
```

---

### Effect isolation proof — `bad_agent.lex`

```sh
lex check examples/bad_agent.lex
# error: effect `net` not declared
```

A compliance agent declared `[sql]` tries to exfiltrate positions via `net.post`. The compiler rejects it. Not a firewall. Not a runtime check. The type system proves it structurally. A prompt injection cannot make a `[sql]` function call `[net]`.

---

## How it works

The agent loop is parameterised over a `decide` function:

```
decide(history) -> Tool
```

For LLM-backed agents: `decide(history) -> [net, llm] (Tool, call_id)`

Each turn the LLM receives the full conversation history and calls exactly one tool:

| Tool | Args |
|---|---|
| `observe` | `target: blotter \| positions \| risk \| audit` |
| `submit_order` | `cl_ord_id, symbol, side, quantity` |
| `cancel_order` | `cl_ord_id, orig_cl_ord_id, symbol, side` |
| `done` | `reason` (becomes the incident report) |

Every step is logged to the lex-trail audit log after dispatch.

---

## Providers

Supports **Anthropic Claude** and **Google Gemini 3.5** (via Vertex AI).

| Variable | Default | Description |
|---|---|---|
| `LLM_PROVIDER` | `anthropic` | `anthropic` or `vertex` |
| `ANTHROPIC_API_KEY` | — | Anthropic API key |
| `ANTHROPIC_MODEL` | `claude-haiku-4-5-20251001` | Any Claude model ID |
| `VERTEX_PROJECT` | — | GCP project ID |
| `VERTEX_ACCESS_TOKEN` | — | `$(gcloud auth print-access-token)` |
| `VERTEX_LOCATION` | `eu` | `eu`, `us`, `global`, or regional |
| `VERTEX_MODEL` | `gemini-3.5-flash` | Any Gemini model on Vertex AI |

---

## In the stack

```
lex-oms  (HTTP order management system)
    ↓
lex-oms-agent  ←  LLM agent layer
```

---

## Install

```toml
[dependencies]
"lex-oms-agent" = { git = "https://github.com/alpibrusl/lex-oms-agent" }
```

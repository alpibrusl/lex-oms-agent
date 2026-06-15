# Arena agent protocol (v0)

Your agent is **any executable, in any language**. The runner invokes it once per
decision step; it reads the episode state from a JSON file and prints exactly one
tool call to stdout. That's the whole protocol.

> **Lex is a first-class agent language too.** Besides the external protocol below,
> a pure-Lex agent can drive the same sim in-process via `run_llm_agent` (see
> `src/arena/runner.lex`), which plugs [lex-llm](https://github.com/alpibrusl/lex-llm)'s
> tool-call loop straight into the episode — no subprocess per step. Pick provider
> and model from the environment, e.g. a local model with no cloud credentials:
>
> ```
> LLM_PROVIDER=ollama LLM_MODEL=devstral-small-2:latest \
>   lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
>     src/arena/runner.lex run_llm_agent '"scenarios/ep2-costs.json"' '"/tmp/trail.jsonl"'
> ```
>
> The output is an ordinary trail file — verified exactly like any other entry.

## Invocation

```
<your_command> <request_path>
```

`<your_command>` is whatever you pass to the runner (e.g. `python3 my_agent.py`).
The runner appends the request file path as the final argument.

## Request file

```json
{
  "step": 2,
  "max_steps": 25,
  "scenario": "ep1-baseline",
  "last_ok": true,
  "last_status": 200,
  "last_body": "<response body of your previous tool call>",
  "history": "0:observe:blotter:ok:200|1:submit_order:AAPL:buy:100:ok:201"
}
```

`history` is compact: `step:tool_name:ok|fail:status`, `|`-separated, oldest first.
Full observation bodies arrive one step at a time through `last_body` — observe,
then read the result on your next invocation.

## Response (stdout, one JSON object)

All eight fields are always required; use `""`/`0` for the ones your call doesn't need.

```json
{"t":"submit","cl_ord_id":"A-001","symbol":"AAPL","side":"buy","quantity":100,"orig_cl_ord_id":"","target":"","reason":""}
```

| `t` | meaning | fields used |
|---|---|---|
| `submit` | submit a market order | `cl_ord_id`, `symbol`, `side` (`buy`/`sell`), `quantity` |
| `cancel` | cancel an open order | `cl_ord_id`, `orig_cl_ord_id`, `symbol`, `side` |
| `observe` | read sim state | `target`: `blotter`, `positions`, `risk`, `audit` |
| `done` | end the episode | `reason` |

Anything unparseable terminates the episode with the error recorded in your trail —
a broken agent produces an honest, verifiable record of breaking.

## Determinism contract

- Don't read clocks, randomness, or anything outside the request file if you want
  your trail to replay — though strictly, **you don't have to be deterministic**:
  the trail records what you decided, and verification replays those decisions.
  Your *reasoning* can be as nondeterministic as you like (LLM calls, dice, vibes).
- One submission = one trail file. The verifier replays it against the scenario and
  recomputes everything. You cannot claim an outcome the sim didn't produce.

## Scoring (v2)

- Every accepted submit fills in full at the scenario's scripted price for its step.
- P&L = Σ signed_qty × (final scripted price − fill price), computed purely from
  the trail + scenario — the same code scores submission and verification.
- Any rejected order (risk/compliance gate) **disqualifies the episode**.
  Performance doesn't count if the perimeter was breached.

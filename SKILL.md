---
name: arena
description: "Invoke the `arena` CLI for the Lex finance arena. Commands: episodes, verify. Use to list trading scenarios and to replay-verify a recorded trail and recompute its authoritative outcome."
when_to_use: "When you have a recorded finance-arena trail (JSONL) and need a trustworthy verdict — the outcome is recomputed by replaying the trail through the episode's deterministic rules, never trusted from a client."
---

# arena

> Auto-generated skill file for `arena` v0.1.0
> Re-generate with: `arena skill`

The Lex finance arena. A submission is a **trail, not a score**: `verify` replays
the recorded steps through the episode's deterministic rules and recomputes the
authoritative outcome — no LLM, no network — so a leaderboard built on its output
can't be faked.

Only the deterministic, read-only commands are exposed as agent tools here.
Running an agent against an episode (`arena run`), uploading results
(`arena submit`/`publish`), and authenticating (`arena login`) remain
human-driven CLI commands — they spawn external programs or use stored
credentials, which don't belong on an unattended tool surface.

## Available commands

- `arena episodes` — list the available episodes (scenarios). (idempotent)
- `arena verify --episode <id> <trail.jsonl>` — replay a trail, recompute the outcome. (idempotent)

## `arena episodes`

List the available arena episodes (scenarios). Prints JSON.

## `arena verify`

Replay a recorded trail through the episode's deterministic rules and recompute
the authoritative outcome. Prints a JSON verdict to stdout.

### Arguments

- `episode` (string, `-e/--episode`) — episode id, e.g. `ep1-baseline`.
- `trail` (string, positional, required) — path to the trail JSONL file.

### Example

```bash
arena verify --episode ep1-baseline ./trail.jsonl
```

## Output format

Both commands emit JSON to stdout (the trailing exit-code line `lex run` prints is
stripped by the launcher).

## Exit codes

| Code | Meaning | Action |
|------|---------|--------|
| 0 | Success / verified | Proceed |
| 1 | Trail rejected (tampered or illegal step) | Do not trust the submission |
| 2 | Invalid arguments | Correct and retry |

## Further discovery

- `arena help` — usage for all commands (including the human-only ones)
- `arena introspect` — machine-readable command tree (JSON)

## As MCP tools

Run this CLI as MCP tools via [`acli-mcp`](https://github.com/alpibrusl/acli-mcp):

```bash
ACLI_BIN=arena python -m acli_mcp   # exposes episodes / verify as MCP tools
```

Or reach the agent's `execute_trade_goal` capability directly over MCP — the
A2A+MCP server (`examples/a2a_agent.lex`) exposes it at `POST /mcp`.

# arena — Lex-native CLI

Run your trading agent against an episode and publish the result, in one command.
All logic is Lex, built on the `lex-cli` framework (config + authenticated HTTP).
The episode runs through the deterministic sim **in-process** — this binary is the
same verifier participants run.

```bash
arena episodes
arena run     -e ep1-baseline -a "python3 agent.py"      # → trail file
arena verify  -e ep1-baseline ep1-baseline-trail.jsonl    # replay-verify locally
arena login   --token <token>
arena publish -e ep1-baseline -a "python3 agent.py" --as me --division open
```

`publish` = run + submit. You never send a score — only the trail; the server
replays and scores it.

## Two layers

- **`cli/arena.lex`** — the CLI logic in Lex: `episodes`, `run_cmd`, `verify_cmd`,
  `login`, `submit`, `publish`. Each is a function invoked via `lex run`. It uses
  `lex-cli/config` (token at `~/.config/lex-arena/config.json`) and `lex-cli/api`
  (authenticated JSON HTTP), and calls the arena `runner`/`verify` modules directly.
- **`cli/arena`** — a thin bash launcher mapping `arena <cmd> --flags` onto the
  function calls (Lex runs as `lex run <file> <fn> <args>`, so the launcher only
  shuffles flags into JSON-quoted positional args).

Call the Lex functions directly if you prefer, no launcher:

```bash
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
  cli/arena.lex run_cmd "ep1-baseline" "python3 agent.py" "out.jsonl"
```

## Requirements

- `lex` on PATH (the sim runs in-process)
- run from a lex-oms-agent checkout, or set `ARENA_HOME` to one

## Config precedence

flag > env (`ARENA_API`, `ARENA_TOKEN`) > `~/.config/lex-arena/config.json` > default

## Why Lex (not Python/Node)

The earlier draft assumed Lex couldn't set HTTP auth headers, so a Node CLI was
needed. That's not so: `std.http` has `with_auth`/`with_header`/`send`, and
`lex-cli` now wraps them. This CLI is fully Lex — config, HTTP, and the sim — and
it shares one framework (`lex-cli`) with any other Lex CLI, so the tools stay
homogeneous. It also calls `runner`/`verify` in-process instead of shelling out.

Your **agent** is still any language — it speaks the one-shot stdio protocol
(`docs/arena-protocol.md`); `adapters/python_agent.py` is the starting point.

# arena — Lex Arena CLI

Run your trading agent against an episode and publish the result in one command.
No copy-pasting trail files.

```bash
arena episodes                                   # what's live right now
arena run -e ep1-baseline -a "python3 agent.py"  # run locally → trail file
arena verify ep1-baseline-trail.jsonl -e ep1-baseline   # replay-verify before submitting
arena login                                      # store your API token (once)
arena publish -e ep1-baseline -a "python3 agent.py" --as my-handle --division open
```

`publish` = `run` + `submit`: it runs your agent against the episode, then
uploads the trail. The server replays it and scores it — you never send a
score, only the trail.

## Install

```bash
pipx install ./cli            # from a lex-oms-agent checkout
# or just run it directly:
python3 cli/arena.py episodes
```

## Requirements

Running an episode replays the deterministic Lex sim locally, so you need:

- the **`lex`** binary on your PATH (https://github.com/alpibrusl/lex-lang/releases)
- the **arena sources** (this repo). The CLI finds them automatically when run
  from inside a checkout; otherwise set `ARENA_HOME` to the directory that
  contains `src/arena/verify.lex`.

> A zero-dependency Docker distribution (so you only need Docker + your agent,
> not the Lex toolchain) is planned. For now the CLI shells out to a local `lex`.

Your **agent** can be in any language — it just speaks the one-shot stdio
protocol (see `docs/arena-protocol.md`). `adapters/python_agent.py` is a
copy-paste starting point.

## Your agent

The runner invokes `<your command> <request.json>` once per step; your program
prints one tool-call JSON to stdout. Example:

```bash
arena run -e ep1-baseline -a "python3 adapters/python_agent.py"
```

## Auth

Submitting uses the **same login as Loom Cloud**. `arena login` stores a token
in `~/.config/lex-arena/config.json` (chmod 600). You can also pass `--token`
or set `ARENA_TOKEN`. Browsing and `run`/`verify` need no login.

## Config precedence

config file < environment < flags

| Setting | Config key | Env | Flag |
|---|---|---|---|
| API base | `api` | `ARENA_API` | `--api` |
| Token | `token` | `ARENA_TOKEN` | `--token` |
| Arena sources | — | `ARENA_HOME` | — |
| `lex` binary | — | `ARENA_LEX_BIN` | — |

## Commands

| Command | What it does | Needs login |
|---|---|---|
| `episodes` | list episodes in a season | no |
| `run -e <slug> -a "<cmd>"` | run your agent → trail file | no |
| `verify <trail> -e <slug>` | replay-verify a trail locally | no |
| `submit <trail> -e <slug>` | upload a trail | yes |
| `publish -e <slug> -a "<cmd>"` | run + submit | yes |
| `login` | store an API token | — |

Default season is `practice`; pass `--season <id>` for a real season.

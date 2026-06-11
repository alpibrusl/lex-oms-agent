#!/usr/bin/env python3
"""arena — friendly CLI for Lex Arena.

Run your agent against an episode and publish the result in one command —
no copy-pasting trail files.

  arena login                              store your API token
  arena episodes                           list current episodes
  arena run -e ep1-baseline -a "python3 agent.py"
  arena verify trail.jsonl -e ep1-baseline
  arena submit trail.jsonl -e ep1-baseline --as me --division open
  arena publish -e ep1-baseline -a "python3 agent.py" --as me

Running an episode needs the `lex` binary and the arena sources (this repo).
Point ARENA_HOME at a lex-oms-agent checkout, or run from inside one.

Config (lowest to highest precedence): config file, env, flags.
  ~/.config/lex-arena/config.json   { "api": "...", "token": "..." }
  env: ARENA_API, ARENA_TOKEN, ARENA_HOME
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_API = "https://loom.alpibru.com"
CONFIG_PATH = Path(os.path.expanduser("~/.config/lex-arena/config.json"))
ALLOW_EFFECTS = "concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time"


# --------------------------------------------------------------------------- config

def load_config() -> dict:
    if CONFIG_PATH.exists():
        try:
            return json.loads(CONFIG_PATH.read_text())
        except json.JSONDecodeError:
            return {}
    return {}


def save_config(cfg: dict) -> None:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2))
    CONFIG_PATH.chmod(0o600)


def api_base(args) -> str:
    return args.api or os.environ.get("ARENA_API") or load_config().get("api") or DEFAULT_API


def token(args) -> str | None:
    return getattr(args, "token", None) or os.environ.get("ARENA_TOKEN") or load_config().get("token")


# --------------------------------------------------------------------------- http

def http_get(url: str) -> dict:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def http_post(url: str, body: dict, bearer: str | None) -> dict:
    headers = {"Content-Type": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


# --------------------------------------------------------------------------- lex sources

def arena_home() -> Path:
    """Locate a lex-oms-agent checkout with src/arena/verify.lex."""
    env = os.environ.get("ARENA_HOME")
    if env:
        p = Path(env)
        if (p / "src/arena/verify.lex").exists():
            return p
        die(f"ARENA_HOME={env} has no src/arena/verify.lex")
    # Search upward from cwd and from this script's location.
    for start in (Path.cwd(), Path(__file__).resolve().parent):
        cur = start
        for _ in range(6):
            if (cur / "src/arena/verify.lex").exists():
                return cur
            cur = cur.parent
    die(
        "Could not find the arena sources. Set ARENA_HOME to a lex-oms-agent\n"
        "checkout (the directory containing src/arena/verify.lex), or run from inside one."
    )


def lex_bin() -> str:
    return os.environ.get("ARENA_LEX_BIN", "lex")


def run_lex(entry: str, fn: str, *fn_args: str) -> subprocess.CompletedProcess:
    """Run `lex run --allow-effects ... <entry> <fn> <json-args...>` in ARENA_HOME."""
    home = arena_home()
    # lex parses argv as JSON — string paths must be JSON-quoted.
    quoted = [json.dumps(a) for a in fn_args]
    cmd = [lex_bin(), "run", "--allow-effects", ALLOW_EFFECTS, entry, fn, *quoted]
    return subprocess.run(cmd, cwd=str(home), capture_output=True, text=True)


# --------------------------------------------------------------------------- episode lookup

def fetch_episodes(base: str, season: str) -> list[dict]:
    return http_get(f"{base}/api/arena/seasons/{season}/episodes").get("episodes", [])


def resolve_episode(base: str, season: str, slug: str) -> dict:
    eps = fetch_episodes(base, season)
    for ep in eps:
        if ep["slug"] == slug:
            return ep
    die(f"Episode '{slug}' not found in season '{season}'. Try: arena episodes")


def write_scenario(ep: dict) -> str:
    sj = ep.get("scenario_json")
    if not sj:
        die(
            f"Scenario for '{ep['slug']}' is not revealed yet (scoring seeds are\n"
            "withheld until the season closes). You can still run practice episodes."
        )
    fd, path = tempfile.mkstemp(prefix=f"{ep['slug']}-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        f.write(sj)
    return path


# --------------------------------------------------------------------------- commands

def cmd_login(args) -> int:
    base = api_base(args)
    tok = args.token
    if not tok:
        print(f"Paste an API token for {base}")
        print("(from the web app while signed in — Settings → CLI token, or your session token)")
        tok = input("token: ").strip()
    if not tok:
        die("no token provided")
    cfg = load_config()
    cfg["api"] = base
    cfg["token"] = tok
    save_config(cfg)
    print(f"Saved to {CONFIG_PATH}")
    return 0


def cmd_episodes(args) -> int:
    base = api_base(args)
    eps = fetch_episodes(base, args.season)
    if not eps:
        print(f"No episodes in season '{args.season}'.")
        return 0
    print(f"Episodes in season '{args.season}':")
    for ep in eps:
        tag = " (practice)" if ep.get("is_practice") else ""
        revealed = "scenario revealed" if ep.get("scenario_json") else "scenario withheld"
        print(f"  {ep['slug']}{tag}  ·  {revealed}  ·  sim v{ep.get('sim_version', '?')}")
    return 0


def do_run(base: str, season: str, slug: str, agent_cmd: str, out_path: str) -> str:
    ep = resolve_episode(base, season, slug)
    scenario_path = write_scenario(ep)
    try:
        print(f"Running {slug} with: {agent_cmd}")
        res = run_lex("src/arena/runner.lex", "run_agent", scenario_path, agent_cmd, out_path)
        info = parse_lex_json(res.stdout)
        if res.returncode != 0 or info is None:
            sys.stderr.write(res.stdout + res.stderr)
            die("episode run failed")
        if "error" in info:
            die(f"runner error: {info['error']}")
        print(
            f"  → {out_path}  ·  {info.get('events')} events  ·  "
            f"{info.get('fills')} fills  ·  pnl {info.get('pnl')}"
        )
        return out_path
    finally:
        os.unlink(scenario_path)


def cmd_run(args) -> int:
    base = api_base(args)
    out = args.out or f"{args.episode}-trail.jsonl"
    do_run(base, args.season, args.episode, args.agent, out)
    return 0


def cmd_verify(args) -> int:
    base = api_base(args)
    ep = resolve_episode(base, args.season, args.episode)
    scenario_path = write_scenario(ep)
    try:
        res = run_lex("src/arena/verify.lex", "verify", scenario_path, args.trail)
        verdict = parse_lex_json(res.stdout)
        if verdict is None:
            sys.stderr.write(res.stdout + res.stderr)
            die("verify produced no output")
        print(json.dumps(verdict, indent=2))
        return 0 if verdict.get("verified") else 1
    finally:
        os.unlink(scenario_path)


def do_submit(base: str, season: str, slug: str, trail_path: str, args) -> int:
    ep = resolve_episode(base, season, slug)
    tok = token(args)
    if not tok:
        die("not logged in — run `arena login` (or set ARENA_TOKEN)")
    trail = Path(trail_path).read_text()
    body = {"trail": trail}
    if args.as_name:
        body["display_name"] = args.as_name
    if args.division:
        body["division"] = args.division
    if args.model:
        body["model_name"] = args.model
    try:
        res = http_post(f"{base}/api/arena/episodes/{ep['id']}/entries", body, tok)
    except urllib.error.HTTPError as e:
        die(f"submit failed ({e.code}): {e.read().decode()[:300]}")
    entry_id = res.get("entry_id")
    status = res.get("status")
    deduped = res.get("deduped")
    print(f"Submitted{' (already existed)' if deduped else ''}: entry {entry_id} [{status}]")
    print(f"  {base.replace('//loom.', '//arena.')}/entry/{entry_id}")
    return 0


def cmd_submit(args) -> int:
    return do_submit(api_base(args), args.season, args.episode, args.trail, args)


def cmd_publish(args) -> int:
    base = api_base(args)
    if not token(args):
        die("not logged in — run `arena login` (or set ARENA_TOKEN) before publishing")
    out = args.out or f"{args.episode}-trail.jsonl"
    do_run(base, args.season, args.episode, args.agent, out)
    return do_submit(base, args.season, args.episode, out, args)


# --------------------------------------------------------------------------- helpers

def parse_lex_json(stdout: str) -> dict | None:
    """Extract the last JSON object from lex output.

    lex prints the program's io.print output and then the Unit return of
    main() as a trailing `null` on the same line, so the verdict line looks
    like `{...}null`. raw_decode parses the leading object and ignores the
    trailing data.
    """
    dec = json.JSONDecoder()
    for line in reversed([l for l in stdout.split("\n") if "{" in l]):
        start = line.find("{")
        try:
            obj, _ = dec.raw_decode(line[start:])
            return obj
        except json.JSONDecodeError:
            continue
    return None


def die(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    sys.stderr.write(msg.rstrip() + "\n")
    sys.exit(1)


# --------------------------------------------------------------------------- argparse

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="arena", description="Lex Arena CLI")
    p.add_argument("--api", help="API base URL (default: https://loom.alpibru.com)")
    p.add_argument("--season", default="practice", help="season id (default: practice)")
    sub = p.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("login", help="store an API token")
    sp.add_argument("--token", help="API token (omit to paste interactively)")
    sp.set_defaults(func=cmd_login)

    sp = sub.add_parser("episodes", help="list current episodes")
    sp.set_defaults(func=cmd_episodes)

    sp = sub.add_parser("run", help="run your agent against an episode → trail file")
    sp.add_argument("-e", "--episode", required=True, help="episode slug")
    sp.add_argument("-a", "--agent", required=True, help='agent command, e.g. "python3 agent.py"')
    sp.add_argument("-o", "--out", help="output trail path (default: <slug>-trail.jsonl)")
    sp.set_defaults(func=cmd_run)

    sp = sub.add_parser("verify", help="replay-verify a trail locally")
    sp.add_argument("trail", help="trail .jsonl file")
    sp.add_argument("-e", "--episode", required=True, help="episode slug")
    sp.set_defaults(func=cmd_verify)

    sp = sub.add_parser("submit", help="upload a trail to the arena")
    sp.add_argument("trail", help="trail .jsonl file")
    sp.add_argument("-e", "--episode", required=True, help="episode slug")
    sp.add_argument("--as", dest="as_name", help="display name")
    sp.add_argument("--division", choices=["open", "local", "scripted"], help="division")
    sp.add_argument("--model", help="model name (self-reported)")
    sp.add_argument("--token", help="override stored token")
    sp.set_defaults(func=cmd_submit)

    sp = sub.add_parser("publish", help="run + submit in one step")
    sp.add_argument("-e", "--episode", required=True, help="episode slug")
    sp.add_argument("-a", "--agent", required=True, help='agent command')
    sp.add_argument("-o", "--out", help="output trail path")
    sp.add_argument("--as", dest="as_name", help="display name")
    sp.add_argument("--division", choices=["open", "local", "scripted"], help="division")
    sp.add_argument("--model", help="model name")
    sp.add_argument("--token", help="override stored token")
    sp.set_defaults(func=cmd_publish)

    return p


def main() -> int:
    args = build_parser().parse_args()
    try:
        return args.func(args)
    except urllib.error.HTTPError as e:
        die(f"HTTP {e.code}: {e.read().decode()[:300]}")
    except urllib.error.URLError as e:
        die(f"network error: {e.reason}")


if __name__ == "__main__":
    sys.exit(main())

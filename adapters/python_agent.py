#!/usr/bin/env python3
"""Arena agent adapter — Python.

Copy this file and replace `decide()` with your strategy (rules, an LLM
call, anything). The runner invokes the script once per step:

    python3 python_agent.py <request_path>

Read docs/arena-protocol.md for the full protocol.
"""

import json
import sys


def tool(t, **kw):
    """Build a complete tool call (all eight fields always present)."""
    base = {
        "t": t,
        "cl_ord_id": "",
        "symbol": "",
        "side": "",
        "quantity": 0,
        "orig_cl_ord_id": "",
        "target": "",
        "reason": "",
    }
    base.update(kw)
    return base


def submit(cl_ord_id, symbol, side, quantity):
    return tool("submit", cl_ord_id=cl_ord_id, symbol=symbol, side=side, quantity=quantity)


def observe(target):
    return tool("observe", target=target)


def done(reason):
    return tool("done", reason=reason)


def decide(req):
    """Example strategy: look at the blotter, buy two names, stop.

    req keys: step, max_steps, scenario, last_ok, last_status,
    last_body, history (see protocol doc).
    """
    step = req["step"]
    if step == 0:
        return observe("blotter")
    if step == 1:
        return submit("PY-001", "AAPL", "buy", 100)
    if step == 2:
        return submit("PY-002", "MSFT", "buy", 50)
    if step == 3:
        return observe("risk")
    return done("python adapter demo complete")


def main():
    with open(sys.argv[1]) as f:
        req = json.load(f)
    print(json.dumps(decide(req)))


if __name__ == "__main__":
    main()

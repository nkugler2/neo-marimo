#!/usr/bin/env python3
"""Smoke check for the F1.3 fix: ws_client.py must not exit 0 on an abnormal
WebSocket close.

This is the first Python-side test in the repo. A full pytest harness felt
like too much scaffolding for one regression, so this is a standalone script
driven from tests/spec/server_spec.lua via vim.system — it monkeypatches
`websockets.connect` to hand `main()` a fake WS whose `async for` iteration
raises `ConnectionClosedError` (simulating a kernel restart / session
eviction), then asserts main() exits nonzero and emits a `neo_marimo_error`
op instead of silently exiting 0 (the bug: asyncio.wait() discarded the
task's exception and the process looked like it shut down cleanly).

Prints "SMOKE_OK" on stdout and exits 0 if the assertions hold; otherwise
prints a diagnostic on stderr and exits nonzero. Requires the `websockets`
package (present in a marimo-equipped python; see NEO_MARIMO_TEST_PYTHON).
"""
import asyncio
import io
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "python"))

import ws_client  # noqa: E402
import websockets  # noqa: E402
from websockets.exceptions import ConnectionClosedError  # noqa: E402


class FakeWS:
    """Stands in for the real WS connection: send() is a no-op, and
    iterating raises ConnectionClosedError to simulate an abnormal close."""

    async def send(self, data):
        pass

    def __aiter__(self):
        return self

    async def __anext__(self):
        raise ConnectionClosedError(None, None)


class FakeConnectCtx:
    async def __aenter__(self):
        return FakeWS()

    async def __aexit__(self, *exc_info):
        return False


websockets.connect = lambda *a, **kw: FakeConnectCtx()

# Capture stdout (ws_client.emit() prints there) without disturbing our own
# diagnostics, which go to stderr.
captured = io.StringIO()
real_stdout = sys.stdout
sys.stdout = captured
exit_code = 0
try:
    asyncio.run(ws_client.main(1234, "smoke-session"))
except SystemExit as e:
    exit_code = e.code if e.code is not None else 0
finally:
    sys.stdout = real_stdout

lines = [line for line in captured.getvalue().splitlines() if line.strip()]
messages = [json.loads(line) for line in lines]

errors = [m for m in messages if m.get("op") == "neo_marimo_error"]

if exit_code == 0:
    print(f"FAIL: exit code was 0, expected nonzero. stdout={lines}", file=sys.stderr)
    sys.exit(1)
if not errors:
    print(f"FAIL: no neo_marimo_error op emitted. stdout={lines}", file=sys.stderr)
    sys.exit(1)

print("SMOKE_OK")
sys.exit(0)

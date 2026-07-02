#!/usr/bin/env python3
"""
neo-marimo WebSocket client.
Connects to a running marimo server and bridges messages to Neovim via stdio.

Usage: ws_client.py <port> <session_id> [filepath] [access_token] [--kiosk]

Stdin:  newline-delimited JSON messages from Neovim → forwarded to the WS
Stdout: newline-delimited JSON messages from the server → consumed by Neovim
Stderr: diagnostic/error messages

Kiosk mode (--kiosk) connects as a secondary "observer" consumer. Marimo's
EDIT mode allows exactly one *main* consumer per file, but any number of
kiosks. That lets nvim sit alongside the browser without kicking it off —
both editors see the same cell-op stream.

Note on send direction: marimo's /ws endpoint is currently server→client.
The server's receive loop only uses incoming frames to detect disconnect.
The stdin → WS pipe below still exists for future use (RTC, or marimo
versions that grow a client-side message protocol), and for verifying the
WS pipe is healthy via :MarimoWsPing.
"""
import asyncio
import json
import sys
import urllib.parse


def emit(msg: dict) -> None:
    """Write a JSON message to stdout for Neovim to read."""
    print(json.dumps(msg), flush=True)


async def _pump_stdin_to_ws(ws) -> None:
    """Read newline-delimited JSON from stdin, forward each line to the WS.

    Runs concurrently with the WS-receive loop. Exits silently when stdin
    closes (ws_client.py is being torn down) so the gather() returns and
    the connection closes cleanly.
    """
    loop = asyncio.get_running_loop()
    while True:
        # readline() in a thread so we don't block the event loop. None / "" on EOF.
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            return  # EOF — parent process exited
        line = line.rstrip("\n")
        if not line:
            continue
        try:
            # Validate JSON before forwarding so a bad line doesn't kill the WS.
            json.loads(line)
        except json.JSONDecodeError as e:
            print(f"ws_client: bad json on stdin: {e}", file=sys.stderr, flush=True)
            continue
        try:
            await ws.send(line)
        except Exception as e:
            print(f"ws_client: send failed: {e}", file=sys.stderr, flush=True)
            return


async def _pump_ws_to_stdout(ws) -> None:
    """Read frames from the WS and emit them on stdout for Lua to consume.

    A closed WS surfaces here one of two ways: the `async for` loop simply
    ends (server closed cleanly, code 1000/1001 — no exception), or it
    raises `ConnectionClosedError` (abnormal: kernel restart, session
    eviction, the session getting dropped from under us). We used to let
    both look the same from the caller's side — the abnormal case
    propagated as an unhandled exception on this task, which `main()`
    never inspected, so it was silently discarded and the process exited
    0. `ConnectionClosedError` is intentionally left uncaught here (not
    swallowed) so it lands on this task's result and `main()` can detect
    it via `task.exception()` and fail loudly instead.
    """
    from websockets.exceptions import ConnectionClosedOK

    try:
        async for raw in ws:
            if isinstance(raw, bytes):
                raw = raw.decode("utf-8")
            try:
                msg = json.loads(raw)
                emit(msg)
            except json.JSONDecodeError:
                pass
    except ConnectionClosedOK:
        # Clean server-initiated close — not an error, nothing to report.
        # Defensive only: websockets 15.x's __aiter__ already swallows
        # ConnectionClosedOK and ends the loop without raising, so this
        # clause never fires today. Kept in case a future websockets
        # version lets the clean close propagate.
        return


async def main(
    port: int,
    session_id: str,
    filepath: str = "",
    access_token: str = "",
    kiosk: bool = False,
) -> None:
    import websockets

    params: dict[str, str] = {"session_id": session_id}
    if filepath:
        params["file"] = filepath
    if access_token:
        params["access_token"] = access_token
    if kiosk:
        params["kiosk"] = "true"
    query = urllib.parse.urlencode(params)
    url = f"ws://127.0.0.1:{port}/ws?{query}"

    try:
        async with websockets.connect(
            url,
            ping_interval=20,
            ping_timeout=10,
            open_timeout=10,
            # No frame-size cap. marimo streams cell outputs as WebSocket
            # frames, and a single rich output — a matplotlib PNG, a large
            # DataFrame's dataresource JSON, an inline data: URI — routinely
            # exceeds the `websockets` default max_size of 1 MiB. When it did,
            # the library closed the connection with code 1009 MESSAGE_TOO_BIG,
            # silently killing the WS mid-run: the oversized cell-op was
            # dropped, every cell-op after it was lost, and the now-detached
            # session made HTTP /api/kernel/run 500 with "Invalid session id".
            # The browser's native WebSocket has no such limit — which is why
            # output always rendered there but not in nvim. None = unbounded,
            # matching the browser; the kernel is local and trusted.
            max_size=None,
        ) as ws:
            emit({"op": "neo_marimo_connected", "session_id": session_id, "port": port})

            # Run send + receive concurrently. If either side errors, the
            # whole connection winds down — preferable to one direction
            # silently hanging while the other reports success.
            recv_task = asyncio.create_task(_pump_ws_to_stdout(ws))
            send_task = asyncio.create_task(_pump_stdin_to_ws(ws))
            done, pending = await asyncio.wait(
                {recv_task, send_task},
                return_when=asyncio.FIRST_COMPLETED,
            )
            for task in pending:
                task.cancel()

            # asyncio.wait() never raises on a failed task — it just marks it
            # done — and an unretrieved task exception is silently dropped by
            # asyncio's default handler. Without this check, an abnormal WS
            # close (kernel restart, session eviction — ConnectionClosedError
            # from _pump_ws_to_stdout) exited this process with code 0, which
            # looked identical to a clean shutdown to server.lua's on_exit
            # (only warns on nonzero). The in-flight run was left stuck at
            # "queued" with nothing left to trigger the resync self-heal.
            for task in done:
                exc = task.exception()
                if exc is not None:
                    emit({"op": "neo_marimo_error", "message": f"WS connection lost: {exc}"})
                    sys.exit(1)

    except ConnectionRefusedError:
        emit({"op": "neo_marimo_error", "message": f"Connection refused on port {port}"})
        sys.exit(1)
    except TimeoutError:
        emit({"op": "neo_marimo_error", "message": f"Connection timed out (port {port})"})
        sys.exit(1)
    except Exception as e:
        emit({"op": "neo_marimo_error", "message": str(e)})
        sys.exit(1)


if __name__ == "__main__":
    argv = sys.argv[1:]

    # --kiosk can appear anywhere; pop it out so positional indexing below
    # stays simple.
    kiosk = False
    if "--kiosk" in argv:
        kiosk = True
        argv = [a for a in argv if a != "--kiosk"]

    if len(argv) < 2:
        print(json.dumps({
            "op": "neo_marimo_error",
            "message": "Usage: ws_client.py <port> <session_id> [filepath] [access_token] [--kiosk]",
        }))
        sys.exit(1)

    port = int(argv[0])
    session_id = argv[1]
    filepath = argv[2] if len(argv) > 2 else ""
    access_token = argv[3] if len(argv) > 3 else ""

    asyncio.run(main(port, session_id, filepath, access_token, kiosk))

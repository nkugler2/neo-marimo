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
    """Read frames from the WS and emit them on stdout for Lua to consume."""
    async for raw in ws:
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8")
        try:
            msg = json.loads(raw)
            emit(msg)
        except json.JSONDecodeError:
            pass


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

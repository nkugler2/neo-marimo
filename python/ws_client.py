#!/usr/bin/env python3
"""
neo-marimo WebSocket client.
Connects to a running marimo server and bridges messages to Neovim via stdio.

Usage: ws_client.py <port> <session_id> [filepath]

Stdout: newline-delimited JSON messages from the server
Stderr: diagnostic/error messages
"""
import asyncio
import json
import sys
import urllib.parse


def emit(msg: dict) -> None:
    """Write a JSON message to stdout for Neovim to read."""
    print(json.dumps(msg), flush=True)


async def main(port: int, session_id: str, filepath: str = "", access_token: str = "") -> None:
    import websockets

    params: dict[str, str] = {"session_id": session_id}
    if filepath:
        params["file"] = filepath
    if access_token:
        params["access_token"] = access_token
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

            async for raw in ws:
                if isinstance(raw, bytes):
                    raw = raw.decode("utf-8")
                try:
                    msg = json.loads(raw)
                    # Forward all server messages to Neovim
                    emit(msg)
                except json.JSONDecodeError:
                    pass

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
    if len(sys.argv) < 3:
        print(json.dumps({"op": "neo_marimo_error", "message": "Usage: ws_client.py <port> <session_id> [filepath]"}))
        sys.exit(1)

    port = int(sys.argv[1])
    session_id = sys.argv[2]
    filepath = sys.argv[3] if len(sys.argv) > 3 else ""
    access_token = sys.argv[4] if len(sys.argv) > 4 else ""

    asyncio.run(main(port, session_id, filepath, access_token))

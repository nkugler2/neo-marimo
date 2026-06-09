#!/usr/bin/env python3
"""
neo-marimo bridge: parse and generate marimo notebook files.

Usage:
  bridge.py parse <filepath>    -> stdout: JSON cell list
  bridge.py generate            -> stdin: JSON cell data, stdout: .py source
  bridge.py check               -> stdout: JSON {ok, python_version, marimo_version}
"""
import json
import re
import sys
from pathlib import Path


# Stable cell-id comments. The Lua side stores per-cell `id` strings and
# we round-trip them through the file via `# id: XXXX\n@app.cell` so a
# reload from disk doesn't mint fresh ids and orphan in-flight cell-op
# messages (Phase 7.5.7). Matches the 4-letter random shape used by
# utils.generate_cell_id() but is tolerant of any [A-Za-z0-9_]+ ids.
ID_COMMENT_RE = re.compile(r"^#\s*id:\s*([A-Za-z0-9_]+)\s*$")


def extract_cell_ids(content: str) -> list:
    """Walk file content and return a list (one entry per cell) of stable
    cell ids parsed from `# id: XXXX` comments immediately preceding each
    `@app.cell` line. Cells without a preceding id comment get None and
    will be minted fresh on the Lua side.
    """
    ids = []
    pending = None
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped:
            continue  # blank lines preserve the pending id binding
        m = ID_COMMENT_RE.match(stripped)
        if m:
            pending = m.group(1)
        elif stripped.startswith("@app.cell"):
            ids.append(pending)
            pending = None
        else:
            # Any other content breaks the id-comment → @app.cell binding,
            # so a stray comment further up doesn't get glued onto the
            # next cell down.
            pending = None
    return ids


def inject_cell_ids(content: str, ids: list) -> str:
    """Insert `# id: XXXX` comments before each `@app.cell` line. Uses the
    decorator's own indentation so the comment lines up. Cells whose id
    is None or empty are left alone (parse will mint one next read).
    """
    out_lines = []
    cell_idx = 0
    for line in content.splitlines(keepends=True):
        stripped = line.lstrip()
        if stripped.startswith("@app.cell") and cell_idx < len(ids):
            cid = ids[cell_idx]
            if cid:
                indent = line[: len(line) - len(stripped)]
                out_lines.append(f"{indent}# id: {cid}\n")
            cell_idx += 1
        out_lines.append(line)
    return "".join(out_lines)


def cmd_check() -> None:
    import platform
    error = None
    try:
        import marimo
        marimo_version = marimo.__version__
        ok = True
    except ImportError as e:
        marimo_version = None
        ok = False
        error = f"marimo not importable from this Python: {e}"

    result = {
        "ok": ok,
        "python_version": platform.python_version(),
        "marimo_version": marimo_version,
    }
    if error:
        result["error"] = error
    json.dump(result, sys.stdout)


def cmd_parse(filepath: str) -> None:
    from marimo._ast.parse import parse_notebook

    content = Path(filepath).read_text(encoding="utf-8")
    result = parse_notebook(content, filepath=filepath)

    if result is None:
        json.dump({"error": "Empty file", "cells": [], "valid": False, "app_options": {}}, sys.stdout)
        return

    ids = extract_cell_ids(content)

    cells = []
    for i, cell in enumerate(result.cells):
        entry = {
            "name": cell.name,
            "code": cell.code,
            "options": cell.options,
        }
        if i < len(ids) and ids[i]:
            entry["id"] = ids[i]
        cells.append(entry)

    json.dump({
        "cells": cells,
        "version": result.version,
        "app_options": result.app.options if result.app else {},
        "valid": result.valid,
        "violations": [
            {"description": v.description, "lineno": v.lineno}
            for v in result.violations
        ],
    }, sys.stdout)


def cmd_generate() -> None:
    from marimo._ast.codegen import generate_filecontents, get_header_comments
    from marimo._ast.cell import CellConfig

    data = json.loads(sys.stdin.read())
    cells = data["cells"]
    filepath = data.get("filepath", "notebook.py")

    # Lua's empty {} round-trips through vim.json.encode as JSON [] (array),
    # so c["options"] can arrive as a list when the cell has no options.
    # Treat anything that isn't a dict as an empty config.
    def _opts(c: dict) -> dict:
        v = c.get("options")
        return v if isinstance(v, dict) else {}

    codes = [c["code"] for c in cells]
    names = [c.get("name", "_") for c in cells]
    cell_configs = [CellConfig.from_dict(_opts(c), warn=False) for c in cells]
    ids = [c.get("id") for c in cells]

    header_comments = get_header_comments(filepath)

    contents = generate_filecontents(
        codes,
        names,
        cell_configs,
        header_comments=header_comments,
    )

    # Inject `# id: XXXX` comments before each @app.cell so a subsequent
    # parse can recover the original ids and avoid the "cell-op for unknown
    # cell" warnings that fire after a reload-from-disk replaces our local
    # ids with freshly-minted ones (Phase 7.5.7).
    if any(ids):
        contents = inject_cell_ids(contents, ids)

    sys.stdout.write(contents)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: bridge.py <parse|generate|check> [filepath]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "parse":
        if len(sys.argv) < 3:
            print("Usage: bridge.py parse <filepath>", file=sys.stderr)
            sys.exit(1)
        cmd_parse(sys.argv[2])
    elif cmd == "generate":
        cmd_generate()
    elif cmd == "check":
        cmd_check()
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)

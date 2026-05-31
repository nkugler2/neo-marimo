#!/usr/bin/env python3
"""
neo-marimo bridge: parse and generate marimo notebook files.

Usage:
  bridge.py parse <filepath>    -> stdout: JSON cell list
  bridge.py generate            -> stdin: JSON cell data, stdout: .py source
  bridge.py check               -> stdout: JSON {ok, python_version, marimo_version}
"""
import json
import sys
from pathlib import Path


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

    cells = []
    for cell in result.cells:
        cells.append({
            "name": cell.name,
            "code": cell.code,
            "options": cell.options,
        })

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

    codes = [c["code"] for c in cells]
    names = [c.get("name", "_") for c in cells]
    cell_configs = [CellConfig.from_dict(c.get("options", {}), warn=False) for c in cells]

    header_comments = get_header_comments(filepath)

    contents = generate_filecontents(
        codes,
        names,
        cell_configs,
        header_comments=header_comments,
    )
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

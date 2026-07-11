# CLAUDE.md — neo-marimo

Orientation for AI assistants working in this repo. Keep it brief; the real
detail lives in the docs linked below.

## What this is

A Neovim plugin (Lua, ~9,700 lines across `lua/neo-marimo/`) that renders and
**live-syncs marimo reactive notebooks** through a Python bridge + WebSocket.
Requires nvim 0.11+ and `curl` on PATH. Single-developer, pre-release.

## Where things are

- `lua/neo-marimo/` — the plugin. Key modules: `init.lua` (attach lifecycle),
  `server.lua` (process + HTTP + WS, ~1000 lines), `sync.lua`, `parser.lua`,
  `output.lua`, `widgets.lua`, `dataframe.lua`, `config.lua` (defaults),
  `health.lua` (`:checkhealth`).
- `python/` — `bridge.py` (parse/generate, spawned per-parse), `ws_client.py`.
- `tests/spec/*.lua` — the spec suite. `tests/fixtures/<series>/` — golden
  `_repr_html_()` captures for marimo 0.19 and 0.23.
- `docs/architecture.md` — the module map (grouped into entry/lifecycle,
  notebook model, kernel connection, output rendering, LSP, and support)
  and the **four extension registries** (`register_output_renderer`,
  `register_widget_renderer`, `register_ws_handler`,
  `register_cell_detector`) — the main contribution surface.
- `docs/plan-release.md` — the current plan (phases **R0–R7**). Pre-release rule:
  **no new features** — correctness, packaging, and contributor on-ramps only.
- `TOCHANGE.md` — the maintainer's backlog. Follow the workflow in its header:
  triage Inbox items into Open, and **delete** items once they ship (the record
  lives in git history / plan docs, never in that file).

## Dev loop

- nvim loads the plugin straight from this dev repo (`make dev-link` /
  rtp `:prepend`). Edits go live on **nvim restart — no commit or push needed**.
- Tests: `make test` (all specs) · `make test FILTER=html` or
  `nvim -l tests/run.lua html` (filter). Marimo-gated specs (bridge round-trips)
  **self-skip** when the interpreter lacks marimo, so the rest run anywhere.
- Re-capture fixtures: `make fixtures` (needs a marimo-equipped python).
- Style gates (`stylua`, `luacheck`) land in plan phase R2; run them once present.

## Rules of the codebase

- **Never strip "why" comments** — they encode hard-won bugs (the 1009
  MESSAGE_TOO_BIG fix in `ws_client.py`, chunked-stdout reassembly and the
  port-conflict identity check in `server.lua`). Add rationale for non-obvious
  fixes.
- The plugin is **intentionally single-instance**: module-level state
  (`server._servers`, `init._attached`, `output._render_ctx`) is by design, not
  a reentrancy bug to "fix."
- Match surrounding style (2-space indent, existing naming). Keep changes scoped;
  add a regression test for bug fixes (`editing_spec.lua` for cell-tracking,
  the matching `*_spec.lua` otherwise).

## AI agent workflow (maintainer's local setup)

The main session runs **Fable 5 as orchestrator**; heavy lifting is delegated to
**Sonnet subagents** defined in `.claude/agents/` (local, gitignored):

- `implementer` — one scoped Lua/Python change → runs `make test` → reports.
- `lua-reviewer` — read-only diff review (correctness + the rules above).
- `docs-writer` — CONTRIBUTING / ROADMAP / CHANGELOG / templates.

Delegate token-heavy or context-polluting work (test runs, diff review, prose)
to a subagent; **do trivial one-liners inline**. For codebase search use the
built-in **Explore** agent; for planning a phase use the **Plan** agent — don't
rebuild those. Never commit or push unless explicitly asked.

---
id: plan-feature-parity
aliases: []
tags: [roadmap, planning]
---

# neo-marimo — Plan: Phase 7 → Feature Parity

This is the forward-looking plan. It picks up where `docs/roadmap.md` leaves off (Phases 4–6 are shipped, see commits `ec5bcdd`, `67ef4d8`, `434c9d9`, `c897975`, and the 2026-06-02 stale-offset sweep) and lays out the path from "usable for editing and running cells" to "full marimo feature parity, keyboard-first, in nvim."

## What's done (recap)

- **Phases 1–3** (`docs/plan.md`): cell rendering, save-sync, headless server + WS, basic stdout output.
- **Phase 4** (`docs/roadmap.md`): Enter-in-strings fix, adaptive cell width, soft-wrap, per-type icons, `:MarimoEdit`/`:MarimoRun`/`:MarimoNewCell` commands.
- **Phase 5** (`docs/roadmap.md`): `:MarimoToggle` view, statusline component, interactive `:MarimoServerList`, cross-phase refactors (renderer registry, WS dispatch, detector chain).
- **Phase 6** (`docs/roadmap.md`): file-watch bidirectional sync, kiosk-mode reconnect so the browser can coexist, `update-cell-codes`/`completed-run` handlers. `/api/kernel/save` was deliberately skipped — see `sync.lua:89-97`.

What remains is sequenced below by priority. Each phase is sized so it lands in one or two focused sessions and either ships a user-visible win or unblocks a later phase.

## Decisions we still need (ask before starting the relevant phase)

These choices affect Phase 7+ scope and shouldn't be locked in by Claude alone:

1. **AI integration (Phase 13)** — call marimo's own AI HTTP API, or bridge to an existing nvim plugin (`avante.nvim`, `copilot.lua`, `codecompanion.nvim`)? Tradeoff: marimo's AI knows about the notebook DAG; nvim plugins know your repo and have richer UX.
2. **RTC mode (Phase 14)** — implement a Yjs CRDT client in Lua, or defer indefinitely and let the file-watch path (Phase 6) carry the long tail? Yjs is heavy; file-watch covers the 95% case.
3. **Multi-column layouts (Phase 11.1)** — render side-by-side cells as actual nvim splits, or as a single buffer with column markers? Splits are visually faithful but break the single-buffer model that makes Phase 6 work.

Bring these up when you start each phase rather than designing in the dark.

---

## Phase 7 — LSP & Hover ✅ SHIPPED (2026-06-03)

**Goal:** `K` shows real hover docs inside the notebook buffer. Completion works through whatever completion plugin the user has. Resolves `TOCHANGE.md` #4.

### 7.1 WS send-side infrastructure ✅

Built as planned. `python/ws_client.py` now runs two concurrent pumps (stdin → WS, WS → stdout), and `server.send_ws(filepath, msg)` writes JSON to the ws_client's stdin via `vim.fn.chansend`. `:MarimoWsPing` exercises the round-trip — pair it with `:MarimoWsDebug` to see the frame leave nvim. The infrastructure exists for future use (Phase 8 widget interactions, hypothetical client-side ops). See 7.2 below for why we did NOT use it for LSP.

### 7.2 Marimo WS-based language features — DEFERRED

Inspection of marimo 0.19.4 source (`_server/api/endpoints/ws_endpoint.py`, `_server/api/endpoints/editing.py`) showed the plan's hypothesis was wrong: **marimo's main `/ws` endpoint is server→client only**. Its receive loop just uses incoming frames to detect disconnect — it has no client-side op protocol. Concretely:

- **Hover / signature / goto-definition**: marimo doesn't expose these over the WS at all. The browser proxies them to a *separate* LSP process (`pylsp`/`basedpyright`/`copilot`) running on a different port — see `_server/lsp.py`. We'd be reimplementing the same client-side LSP, just talking to marimo's bundled server. Not worth the extra moving piece.
- **Completion**: marimo *does* have `POST /api/kernel/code_autocomplete` → kernel response over the WS as a `completion-result` notification. But `KIOSK_EXCLUDED_OPERATIONS` in `ws_message_loop.py` filters that notification out for kiosk consumers — and our default mode is kiosk (so the browser can co-edit). Promoting to main just to read completions would steal the slot back from the browser.

Decision: rely on the user's existing Python LSP (pyright/basedpyright/pylsp) through the shadow buffer (7.3). It gives all four LSP ops, has zero marimo-server coupling, and works whether or not a kernel is running.

If a follow-up phase wants marimo-kernel-aware completion as a *supplement*, the path is: connect a transient main-mode WS just for the completion exchange, parse the `completion-result` notification, merge with pyright results. Captured here so it's not lost.

### 7.3 Shadow-buffer LSP (now the primary path) ✅

`lua/neo-marimo/lsp.lua` maintains a hidden `nofile` buffer per notebook (named under `stdpath("cache")/neo-marimo/shadow/...` so its URI is a real `file://` — pyright rejects custom schemes). Shape per cell:

```
#@cell N [type]
def __cell_N():
    <cell code, indented +4>
```

Wrapping each cell in `def __cell_N():` makes top-level `return` statements (common in marimo cells) parse cleanly, at the cost of cross-cell goto-def (each cell is its own scope). The trade-off was deliberate: reproducing marimo's real codegen (`@app.cell`, `app._unparsable_cell(r"""…""")`) would make position translation brittle because different cells get wrapped differently.

- Refreshed on edit (debounced 500ms via `on_bytes`) and on demand before each LSP request.
- LSP attachment: `ensure_lsp_attached(bufnr)` finds any live Python LSP client and attaches it via `vim.lsp.buf_attach_client`. Production nvim already has pyright running on the user's other Python buffers, so this is near-instant. Cold-start fallback fires `FileType=python` to nudge the user's autostart machinery (e.g. `vim.lsp.enable("pyright")`).
- Position translation: see `notebook_to_shadow_pos` / `shadow_to_notebook_pos`. Roundtrip verified with synthetic + real-notebook tests.

### 7.4 Glue ✅

`keymaps.lua` binds (overridable in `config.keymaps`):

| Mode | Default | Action |
|------|---------|--------|
| `n`  | `K`        | `lsp.hover()` |
| `i`  | `<C-k>`    | `lsp.signature()` |
| `n`  | `gd`       | `lsp.goto_definition()` |
| —    | omnifunc   | `v:lua.neo_marimo_omnifunc` → `<C-x><C-o>` |

`lsp.is_in_markdown_string` suppresses requests on lines inside a `mo.md("""…""")` body — but the opener row (containing `mo.md(`) still gets routed so hover on `mo.md` works.

**Phase 7 verification:**

1. ✅ With pyright (or basedpyright/pylsp) running on the user's Python files: `K` on `pd.DataFrame` shows hover via the shadow buffer. End-to-end test with marimo notebook `test_db.py` + the user's mason-managed pyright returned the `duckdb` module docstring at the cursor position.
2. — The marimo-WS path was deferred (see 7.2). The shadow-buffer path works whether or not the kernel is running, so there's no "stop the server" scenario to test.
3. ✅ `<C-x><C-o>` (omnifunc → `neo_marimo_omnifunc`) drives completion via the shadow buffer. Tested against pyright on `os.<here>` — 311 items returned (`__name__`, `path`, `environ`, …).
4. ⚠ `gd` jumps within the *same cell* because each cell is wrapped in its own `def __cell_N():`. Cross-cell goto-def is a known limitation of the shadow shape and would require either hoisting imports/definitions to module scope (extra static analysis) or mirroring marimo's codegen verbatim (brittle reverse-translation). Filed mentally as "could-improve, not blocking."
5. ✅ Hover inside `mo.md("""\n…\n""")` body returns nothing — `is_in_markdown_string` short-circuits before the LSP request.

---

## Phase 8 — Rich Output (markdown + kitty graphics + widgets) (≈4–5 days)

**Goal:** the browser is no longer required for the common case. Resolves `TOCHANGE.md` #2.

### 8.1 Markdown rendering for `mo.md(...)` output

Marimo sends `mo.md()` results as `text/markdown` (already pre-rendered to HTML actually — re-check). Replace the current "strip tags → plain text" path with proper treesitter-highlighted virt_lines.

- Output renderer for `text/markdown`: split by line, use `vim.treesitter.get_string_parser(line, "markdown")` for inline highlights.
- Headings: prefix `▍ `, apply `@markup.heading` highlight, bold.
- Lists: `• ` markers with `@markup.list`.
- Code blocks: prefix `▏ `, inject treesitter for the language tag.
- Inline code spans: `@markup.raw.markdown_inline`.
- Distilled from render-markdown.nvim; ~150 LOC, no plugin dep.

### 8.2 Image rendering via kitty graphics protocol

ghostty (the user's terminal) supports the kitty graphics protocol natively.

- New `lua/neo-marimo/image.lua` wrapping the kitty graphics escape sequences (base64-encode PNG bytes, emit `\x1b_Ga=T,f=100,…\x1b\\`).
- Detect `image.nvim` / `snacks.image` at setup time and delegate when available; otherwise hand-roll the escapes.
- Register renderers for `image/png`, `image/jpeg`. SVG via `rsvg-convert` if installed, placeholder otherwise.
- For matplotlib (which arrives wrapped as `text/html` with a `data:image/png;base64,…` URI), extract the base64 payload in `render_html` and route it through the image renderer instead of the current placeholder.

### 8.3 Interactive widget rendering (`mo.ui.*`)

Marimo sends widgets as `application/vnd.marimo+mime` with a JSON descriptor. Render each known widget type as an editable ASCII control with a key-driven update path.

Cover the top widgets first:

| Widget        | Rendering                              | Key bindings (on the widget line)    |
| ------------- | -------------------------------------- | ------------------------------------ |
| `slider`      | `[━━━●━━━] 0.42`                       | `←`/`→` step, `=` set value (prompt) |
| `button`      | `[ Click ]`                            | `<CR>` to press                      |
| `text`        | `[ "hello" ]`                          | `c` to change (prompt)               |
| `text_area`   | Multi-line bordered box, edit on `<CR>` | `<CR>` to edit                      |
| `checkbox`    | `[x] label` / `[ ] label`               | `<CR>` to toggle                    |
| `dropdown`    | `[ value ▾ ]`                          | `<CR>` opens telescope-style picker  |
| `multiselect` | `[ a, b ▾ ]`                           | `<CR>` opens picker, `<Tab>` toggles |
| `number`      | `[ 42 ]`                               | `+`/`-` step, `=` set                |

- Widget interactions send WS update ops (using the Phase 7 `send_ws` path) and re-render on response.
- Register a per-widget keymap dispatcher keyed on cursor row.

### 8.4 Layout primitives (`mo.hstack`, `mo.vstack`, `mo.tabs`, `mo.accordion`)

Render as nested ASCII boxes inside the cell output area. `mo.tabs` has selectable tab headers (`<Tab>`/`<S-Tab>`).

### 8.5 DataFrame side-panel (`<leader>mD`)

Current ASCII table tops out at 5 rows. Add:

- `<leader>mD` opens a side split (vsplit on the right) with the full DataFrame.
- Reuse the existing renderer with no row cap, plus a `?` keymap for help.
- Column sort: `s` on a column header.

**Phase 8 verification:**

1. `mo.md("# Hello")` renders as a styled heading (not raw HTML).
2. `plt.show()` renders the plot inline below the cell (in ghostty/kitty).
3. `mo.ui.slider(0, 1, 0.01)` shows as ASCII; arrow keys mutate the value and dependent cells re-run.
4. `mo.hstack([a, b, c])` renders three boxes side-by-side.
5. `<leader>mD` on a DataFrame cell opens the side panel.

---

## Phase 9 — Execution Control & Reactive Awareness (≈2–3 days)

**Goal:** when something runs forever, hangs, or fills memory, you can interrupt and recover without leaving nvim. When a cell errors, you can see why and what depends on it.

### 9.1 Cell interrupt + kernel restart

- `<leader>mi` (`:MarimoInterrupt`) — POST `/api/kernel/interrupt`.
- `<leader>mK` (`:MarimoRestart`) — POST `/api/kernel/restart`. Clears all cell outputs and statuses, keeps the buffer untouched.
- Show toast notification with what was interrupted (`"interrupted cell #3"`).

### 9.2 Cell-dependency graph (`:MarimoDeps`)

Marimo exposes a `cell-deps` WS op (or similar — confirm name) that returns `{cell_id: {refs: [...], defs: [...]}}`.

- `:MarimoDeps` opens a floating window showing an ASCII DAG of cells with their `defs → refs` edges.
- `<CR>` on a node jumps the main buffer to that cell.
- `r` re-runs the selected cell.
- Highlight the cell under the cursor in the main buffer with a different border color.

### 9.3 Variable explorer (`:MarimoVars`)

Marimo's `variables` WS op streams all top-level definitions with type and a short repr.

- `:MarimoVars` opens a side split (left) listing every variable, type, value preview.
- `<CR>` jumps to the cell that defines it.
- `f` enters filter mode (live regex).
- Auto-update on `cell-op idle`.

### 9.4 Cell config (`disabled`, `hide_code`)

- `<leader>mD` is taken by Phase 8.5; use `<leader>mc` for cell config menu.
- Menu items: toggle disabled, toggle hide_code, set column. Persists to `cell.options` and round-trips through the bridge.
- Visual treatment: disabled cells get a dimmed border + `disabled` label (already partially there from Phase 4.3); hide_code cells render as a single-line bar with just the label.

**Phase 9 verification:**

1. `<leader>mi` mid-`while True:` cell stops the cell within ~200ms and shows `interrupted`.
2. `<leader>mK` clears all outputs and the next `<leader>mR` re-runs from scratch.
3. `:MarimoDeps` shows the DAG; `<CR>` jumps.
4. `:MarimoVars` shows all vars; defining a new one updates the list.
5. `<leader>mc` → "toggle disabled" greys out the cell.

---

## Phase 10 — Database Connections for SQL Cells (≈2 days)

**Goal:** when a SQL cell runs, the user can pick which database connection (defined in earlier Python cells) it targets. Closes `docs/add-to-roadmap.md` item #1.

### 10.1 Connection discovery

- Static scan of the notebook for known patterns: `duckdb.connect(...)`, `sqlalchemy.create_engine(...)`, `psycopg.connect(...)`, `clickhouse_driver.Client(...)`. Extract the variable name and connection target.
- Track via `nb.connections = [{name = "db", kind = "duckdb", target = ":memory:"}, …]`.
- Re-scan on every save + on `update-cell-codes`.

### 10.2 SQL cell metadata

Marimo's `mo.sql(...)` cells accept an `engine=` kwarg that selects which connection to use. Add a per-cell config field `cell.sql_engine` that maps to a connection name.

- When generating the .py via the bridge, emit the `engine=` kwarg if set.
- Detect existing `engine=` on parse and populate `cell.sql_engine`.

### 10.3 `:MarimoSqlConnect` picker

- On a SQL cell: `:MarimoSqlConnect` opens a floating picker of known connections.
- `<CR>` sets `cell.sql_engine` and marks notebook dirty.
- Display the current connection in the cell border label (`󰆼 sql · db`).

### 10.4 Schema preview (stretch)

If the connection is a DuckDB or SQLAlchemy engine and the kernel is running, query the schema and show it in the LSP completion path from Phase 7 — table names complete after `FROM `, column names complete inside `SELECT`.

**Phase 10 verification:**

1. Notebook with a Python cell `db = duckdb.connect(":memory:")` and a SQL cell. `:MarimoSqlConnect` lists `db`.
2. Selecting `db` updates the border to `󰆼 sql · db` and the saved file shows `mo.sql("…", engine=db)`.
3. Running the SQL cell hits the right database.

---

## Phase 11 — Layout & Navigation (≈3 days)

**Goal:** notebooks with structure (sections, columns, lots of cells) are navigable without scrolling forever.

### 11.1 Multi-column layout (marimo `column` cell config)

> **Decision needed (see top of doc).** Options: (a) render each column as a vertical split, (b) stack columns in a single buffer with a divider marker.

Recommended: (b) for Phase 11, deferring (a) to a flag in a later phase. Buffer-stacked is faithful enough for most workflows and doesn't break the file-watcher path.

### 11.2 Outline view (`:MarimoOutline` / `<leader>mO`)

- Extract all `mo.md(...)` headings and cell `name`s.
- Render in a floating window (telescope-style) or vertical split.
- `<CR>` jumps to the cell.

### 11.3 Find/replace within cells (`:MarimoFind`)

- Wraps `:%s/foo/bar/g` but operates cell-by-cell and re-renders after each.
- Mostly a convenience over the existing buffer-wide search; the win is making it cell-aware (replace in code only, not in `mo.md` strings unless requested).

### 11.4 Cell focus / folding

- `<leader>mz` (zoom): hide every cell except the one under cursor (folds others).
- `<leader>mZ` (un-zoom): restore.
- Uses `nvim_buf_set_extmark` with `conceal` lines, not real vim folds (which interact badly with extmark virt_lines).

### 11.5 Cell drag-style reorder (`:MarimoReorder`)

- Opens a floating list of cells (`<C-j>`/`<C-k>` to move the highlighted one).
- `<CR>` applies the new order via repeated `move_cell_down`/`up`.

**Phase 11 verification:**

1. Notebook with two columns renders both, visually divided.
2. `<leader>mO` shows headings, jumps work.
3. `:MarimoFind foo` replaces only in code cells, not in markdown strings.
4. `<leader>mz` zooms; `<leader>mZ` restores.
5. `:MarimoReorder` lets you swap cells without manual `<leader>mJ`/`mK` spam.

---

## Phase 12 — App Mode + Export (≈2 days)

**Goal:** the read-only "run my notebook as a webapp" mode marimo ships with, accessible from nvim. Export to common formats without a separate CLI invocation.

### 12.1 App mode

- `:MarimoRunApp` — POST to start `marimo run` (different mode than `marimo edit`), open in browser.
- Distinct from `:MarimoEdit`: this is the deployment-ready view, no code editing, just the rendered outputs.

### 12.2 Export

- `:MarimoExport html` — `marimo export html notebook.py -o notebook.html`.
- `:MarimoExport ipynb` — same for ipynb.
- `:MarimoExport md` — markdown export.
- `:MarimoExport script` — strip the marimo decorators and produce a runnable .py script.

Each shells out to the existing `marimo` CLI; we don't reimplement them.

### 12.3 WASM playground link

- `:MarimoShare` opens the notebook on `marimo.app/?notebook=<base64>` in the browser, for ad-hoc sharing.

**Phase 12 verification:**

1. `:MarimoRunApp` launches the app view in browser; code is not editable.
2. `:MarimoExport html` produces `notebook.html` next to the source.
3. `:MarimoShare` opens a working playground link.

---

## Phase 13 — AI Integration (≈3–5 days)

**Goal:** the AI features marimo's browser offers (generate cell, edit cell, chat) reachable from nvim.

> **Decision needed before starting.** Three viable paths; the user should pick:
>
> 1. **Marimo's own AI** — call marimo's `/api/ai/*` endpoints. AI sees the notebook DAG and variable state. Locked to marimo's prompts and models.
> 2. **Bridge to existing nvim AI plugins** (`avante.nvim`, `codecompanion.nvim`). Richer UX, but AI sees flat .py without notebook context.
> 3. **Roll our own using the Anthropic SDK** with a context builder that includes nearby cells + variable explorer output. Most flexible, most work.

### 13.1 AI cell generation (`<leader>maa`)

- Floating prompt window. User describes what they want.
- Generates a new cell below the cursor (or replaces the current one).
- Pre-fills with `# AI-generated` comment so it's spottable in diff.

### 13.2 AI cell edit (`<leader>mae`)

- On a cell, opens a prompt for "what to change."
- Diff-applies the response to the cell.

### 13.3 AI chat side panel (`<leader>mac`)

- Vertical split with chat history.
- `<CR>` in insert mode submits.
- Cell-context aware (mentions the cell under cursor in the system prompt).

**Phase 13 verification depends on which path is chosen** — defer concrete steps until the decision lands.

---

## Phase 14 — RTC Mode (Yjs CRDT) (≈5–7 days, defer indefinitely?)

**Goal:** replace the file-watch path with true simultaneous editing — multiple humans + AI agents can edit the same notebook live, with no conflict on overlapping edits.

> **Decision needed.** Phase 6's file-watch path covers the 95% case. Yjs is a large dep and Lua doesn't have a mature client. Honest recommendation: skip this for now, revisit only if multi-user editing becomes a real pain point.

If we do it:

- `python/ws_client.py` switches to `MARIMO_RTC=true` mode and proxies Yjs awareness + delta messages.
- Lua side maintains a Y.Doc-equivalent state machine (probably wrapped via FFI to a Rust Yrs binding).
- Cursor positions broadcast as Yjs awareness.

---

## Phase 15 — Programmatic & Notebook Tooling (≈2–3 days)

**Goal:** small quality-of-life wins around marimo's programmatic features.

### 15.1 `mo.cli_args()` integration

- `:MarimoArgs key=value …` sets args for the next run.
- Persists in `nb._cli_args` and gets passed on `<leader>mr` / `<leader>mR`.

### 15.2 `mo.query_params()` integration

- Same shape as 15.1 but for URL params (matters when opening the app view in browser).

### 15.3 Persistent cache awareness

- `mo.persistent_cache(name)` cells get a cache-icon in the border (`󰄉 cached`).
- `<leader>mx c` clears the cache for the cell under cursor.

### 15.4 `mo.notebook_dir()` / `mo.notebook_location()`

These work transparently — nothing to do but document in `doc/neo-marimo.txt`.

### 15.5 Templates and snippets

- `:MarimoNew` (already exists) gets a `--template` arg: `blank` (default), `data-analysis`, `dashboard`, `tutorial`. Pulls from `marimo new --template`.
- Snippets library: hook into nvim's snippet system (LuaSnip) with a marimo snippets pack (`mo.ui.slider`, `mo.md` skeleton, etc.).

**Phase 15 verification:**

1. `:MarimoArgs threshold=0.5` then `<leader>mR` — code that reads `mo.cli_args().get("threshold")` sees `0.5`.
2. Cell with `mo.persistent_cache("foo")` shows the cache icon.
3. `:MarimoNew --template data-analysis` creates a notebook with the analysis template.

---

## Out of scope (intentional)

Items in marimo's browser that don't belong in a keyboard-first nvim plugin:

- **Drag-and-drop UI** — `:MarimoReorder` (Phase 11.5) covers the same need.
- **File browser** — telescope, oil.nvim, etc. already do this better.
- **Settings UI** — `require("neo-marimo").setup({…})` is the config surface.
- **Theme picker** — nvim colorschemes are upstream.
- **Visual git diff inside the notebook** — gitsigns/fugitive handle this.
- **Tutorials embedded in the editor** — `marimo tutorial` opens the browser; that's fine.

---

## Suggested execution order

If you ship phases in this order, each one delivers a noticeable workflow improvement on its own:

1. **Phase 7** (LSP) — biggest pain point; makes editing feel like real Python.
2. **Phase 9** (execution control) — interrupt + restart unblock common "kernel hung" situations.
3. **Phase 8.1 + 8.2** (markdown + images) — most-requested rich-output bits.
4. **Phase 10** (database connections) — closes a known backlog gap.
5. **Phase 8.3 + 8.4** (widgets + layout primitives) — heavier, but unlocks the "I don't need the browser" milestone.
6. **Phase 11** (navigation) — pays off once notebooks have grown to ~20+ cells.
7. **Phase 12** (app mode + export) — small, mostly shelling out.
8. **Phase 15** (programmatic) — incremental QoL.
9. **Phase 13** (AI) — high upside but blocked on the integration-path decision.
10. **Phase 14** (RTC) — defer until file-watch's limits actually bite.

After Phase 15 (and possibly 13), neo-marimo covers everything a marimo user does in the browser, minus the marimo-cloud-hosted features (deployment, multi-tenant). For solo / small-team notebook work it would be at full parity.

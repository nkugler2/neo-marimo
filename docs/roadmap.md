---
id: roadmap
aliases: []
tags: []
---

# neo-marimo — Roadmap: Phases 4 → 8

## Context

Phases 1–3 of the original plan (`docs/plan.md`) shipped: cell rendering, save-sync, headless server + WS, and basic stdout output. The plugin is usable for editing and running cells, but several workflow blockers and feature-parity gaps remain (captured in `TOCHANGE.md` and the "not yet implemented" list in `docs/plan.md`).

This roadmap covers the next five phases. Goals (in priority order):

1. Fix workflow blockers that make day-to-day editing painful (Enter-in-strings, cell width, hover, view toggle).
2. Add visibility and control (statusline, distinct cell types, server introspection). Some of this is already added, so check what has been added first before making changes.
3. Unlock bidirectional editing so the marimo browser can coexist with neovim.
4. Bring rich rendering (markdown, plots, widgets) into the ghostty terminal so we don't _need_ the browser for most workflows.
5. Lay down extension points so adding the long tail of marimo-parity features later is cheap.

**Decisions captured from clarifying questions:**

- **Bidirectional sync**: ship file-watch + auto-disconnect first (Phase 6), RTC later (post-Phase 8).
- **Terminal**: kitty/WezTerm/Ghostty — native graphics protocol available for Phase 8.
- **LSP/hover**: marimo's WS-based LSP first, pyright shadow-buffer fallback (Phase 7).
- **Cell-type distinction**: nerd-font icons + color, rounded border preserved (Phase 4).

---

## Cross-phase architectural changes

Three small refactors land alongside Phase 4 so the rest of the roadmap plugs in cleanly. Each is small (<100 LOC) and self-contained.

### Registry pattern for output renderers — `lua/neo-marimo/output.lua`

Replace the hardcoded `if mime == "text/plain" then …` chain with a registry table:

```lua
M.renderers = {} -- mimetype -> function(payload, opts) -> virt_lines
function M.register_renderer(mime, fn) M.renderers[mime] = fn end
```

Renderers for `text/plain`, `text/html`, `text/markdown`, `application/vnd.dataresource+json`, `image/*`, `application/vnd.marimo+error`, `application/vnd.marimo+mime` move into the registry. Phase 8 image/widget renderers register themselves at setup time.

### WS message dispatch table — `lua/neo-marimo/init.lua`

Replace the if-chain in `nb._on_ws_message` (lines 109–130) with:

```lua
local ws_handlers = require("neo-marimo.ws_handlers")
ws_handlers.dispatch(op, payload, nb)
```

New file `lua/neo-marimo/ws_handlers.lua` exposes `register(op, fn)` and `dispatch(op, payload, nb)`. Built-in handlers register at module load for `cell-op`, `kernel-ready`, `neo_marimo_connected`, `neo_marimo_error`. Phase 6 registers `update-cell-codes`, `completed-run`; Phase 7 registers `completion-result`, `hover-result`.

### Cell-type detector chain — `lua/neo-marimo/cell.lua`

`detect_type` becomes a list of `(predicate, type)` pairs walked in order. Phase 4 adds the `mo`-widget detector (`mo.ui.*`, `mo.hstack`, etc.) without touching the others.

> **Why this matters now:** none of these refactors change behavior; they just collapse three hardcoded branch chains into tables that the rest of the roadmap appends to. Without them, every later phase touches the same three functions and they grow into 200-line spaghetti.

---

## Phase 4 — Workflow Fixes (≈3–4 days)

**Goal:** make day-to-day editing not feel broken. After this phase, Enter works, code stays visible, cell types are obvious, and the missing user commands exist.

### 4.1 Fix Enter in multi-line strings (`TOCHANGE.md` #8) — **critical**

**Root cause:** `buffer.lua:223 on_text_changed` attributes line-count deltas to _the cell containing the cursor_. When you press Enter mid-cell, the cursor moves down one row before the debounced handler fires, so it lands at `cell[i+1].start_row` (cells are contiguous) and the delta gets assigned to the wrong cell. On save, cell _i_ becomes `mo.md("""test` (unterminated string → syntax error), cell _i+1_ becomes `text""")` + original code.

**Fix:** swap the `TextChanged`/`TextChangedI` autocmd for `vim.api.nvim_buf_attach(bufnr, false, { on_bytes = ... })`. `on_bytes` callbacks include `(start_row, start_col, old_end_row, old_end_col, new_end_row, new_end_col)` — we know exactly _where_ the change happened and can attribute the delta to whichever cell contains `start_row` (the position _before_ the change), not the cursor.

Key files:

- `lua/neo-marimo/buffer.lua`: refactor `on_text_changed` → `on_bytes_changed(start_row, old_end_row, new_end_row, …)`. Compute `delta = (new_end_row - old_end_row)` and apply to the cell containing `start_row`.
- `lua/neo-marimo/init.lua`: replace `nvim_create_autocmd("TextChanged*")` with `nvim_buf_attach(bufnr, false, { on_bytes = … })`. Still debounce (`utils.debounce`) since `on_bytes` fires per-keystroke.

**Verification:** open a notebook, type `mo.md("""test`, press Enter, type `text""")`, `:w`, reopen — cell content is preserved as a single multi-line string.

### 4.2 Window-adaptive cell borders + soft-wrap (`TOCHANGE.md` #1)

Two layered fixes:

- **Adaptive border width**: `buffer.lua` currently hardcodes `BORDER_WIDTH = 72`. Replace with `width = math.max(40, vim.api.nvim_win_get_width(win) - signcolumn_width - numberwidth)`. Re-render borders on `WinResized` and `WinScrolled` autocmds (debounced 100ms).
- **Code soft-wrap**: set buffer-local `wrap = true`, `linebreak = true`, `breakindent = true`, `showbreak = "↳ "` in `buffer.create`. Add config option `ui.wrap_cells = true` (default on) so power users can override.

Borders draw at the _visible_ window width, code wraps within that width. No horizontal scroll needed for the common case; users with extremely long lines can still `:set nowrap` locally.

### 4.3 Per-type icons + `mo` widget cell detection (`TOCHANGE.md` #7)

- **Icons in label**: change the `type_labels` table in `buffer.lua:19` to:
  ```lua
  python   = "  py ",   -- nf-fa-python
  markdown = "md ",  -- nf-md-language_markdown
  sql      = " 󰆼 sql ",  -- nf-md-database
  marimo   = " 󰀘 mo ",   -- nf-md-meteor (any nerd-font glyph)
  ```
  Add config option `ui.icons = true | false` so users without a nerd font can disable.
- **`mo` detection**: extend `cell.detect_type` chain to add a "marimo" type when the cell body is _only_ `mo.ui.*`, `mo.hstack`, `mo.vstack`, `mo.tabs`, etc. with no surrounding logic. Heuristic: trimmed code starts with `mo.` and ends with `)`, no `=`, no `def`, no `import`.
- **New highlight group**: `MarimoCellMarimoBorder` and `MarimoCellMarimoLabel` in `lua/neo-marimo/highlights.lua`, color `#E6C384` (warm yellow — distinct from py/md/sql).

### 4.4 `:MarimoEdit`, `:MarimoRun`, `:MarimoNew` user commands (plan.md pending)

`:MarimoNew` already exists for "create new notebook" — keep it.

- **`:MarimoEdit`**: alias for `<leader>mo` (start server + open browser). Argument-less.
- **`:MarimoRun [all]`**: no arg = run cell at cursor; `:MarimoRun all` = run all cells. Calls the existing keymap actions.
- **`:MarimoNewCell [above|below]`**: explicit alternative to `<leader>mn` / `<leader>mN`. (Rename from the original plan's `:MarimoNew` since that name is taken.)

Critical files: `plugin/neo-marimo.lua` (where `nvim_create_user_command` calls live).

**Phase 4 verification:**

1. Open a notebook → cell borders span window width, code wraps cleanly.
2. Type a multi-line `mo.md("""…""")` with Enters inside → `:w` → `cat file.py` → string is intact.
3. Cells show `  py`, `  md`, `󰆼 sql`, `󰀘 mo` icons (with nerd font installed).
4. `:MarimoEdit` opens browser; `:MarimoRun` runs current cell.

---

## Phase 5 — Toggle View, Statusline, Server Introspection (≈2 days)

**Goal:** users can dip in/out of the notebook view and always see whether a server is running.

### 5.1 Toggle marimo view on/off (`TOCHANGE.md` #5)

Add `:MarimoToggle` and `<leader>mv`:

- If current buffer is the notebook view (`marimo://` prefix): swap window to a freshly-opened plain `.py` buffer at the same filepath, keep notebook state in `_attached` so we can swap back.
- If current buffer is the underlying `.py` and `_attached[filepath]` exists: swap window back to `_attached[filepath].bufnr`.
- If on plain `.py` with no notebook state: trigger `attach(bufnr)`.

Critical files:

- `lua/neo-marimo/init.lua`: add `M.toggle(bufnr)`.
- `lua/neo-marimo/keymaps.lua`: bind `<leader>mv` on both notebook and underlying buffers.
- `plugin/neo-marimo.lua`: register `:MarimoToggle`.

The notebook buffer's `BufWipeout` autocmd currently stops the server on close (init.lua:162); change it to only stop if the user really wants — the toggle should _not_ nuke the server. Move the stop-on-wipe behavior to a config flag `server.stop_on_close = false` (default).

### 5.2 Statusline component (`TOCHANGE.md` #6)

New file `lua/neo-marimo/statusline.lua`:

```lua
function M.component()      -- returns a short status string
function M.servers()        -- returns array of {filepath, port, ws_connected}
function M.current_cell()   -- returns "py · #3 / 12" for current notebook
```

`M.component()` returns e.g. `"󰀘 marimo · 2 servers · py #3/12"` when active, `""` otherwise. The component re-evaluates lazily — statusline plugins call it on redraw.

Document the integration snippet in `doc/neo-marimo.txt`:

```lua
-- lualine:
require("lualine").setup({
  sections = { lualine_x = { require("neo-marimo.statusline").component } },
})
```

`:MarimoServerList` already exists — extend it to also show ws_connected status, cell count, and an option to `<leader>mo` from the list buffer to switch to any open notebook.

### 5.3 Architecture refactors (the three cross-phase changes above)

Land the renderer registry, WS dispatcher, and detector chain here. Each is a no-op refactor that keeps `:checkhealth neo_marimo` green.

**Phase 5 verification:**

1. `:MarimoToggle` flips between notebook view and raw `.py` — toggling does not stop the server.
2. With lualine wired to `neo-marimo.statusline.component`, the statusline shows server count + current-cell index when on a notebook.
3. `:MarimoServerList` shows ws_connected status for each managed server.
4. Existing keymaps and output rendering still work (no behavior regression from the refactors).

---

## Phase 6 — Bidirectional Sync (file-watch path) (≈4–5 days)

**Goal:** edits in nvim show up in the browser within ~300ms, edits in the browser show up in nvim within ~300ms, and the browser is no longer locked out when a notebook is open in nvim.

### 6.1 Unblock the browser — auto-disconnect on `:MarimoOpen`

Marimo's EDIT mode allows exactly one WS connection per file. When the user calls `<leader>mo` / `:MarimoEdit`, we currently win the race and the browser sees "Network already connected".

Fix: when the user opens the browser, gracefully disconnect _our_ WS, write a flag on `srv.browser_active = true`, and let the browser connect. Re-establish our WS automatically when:

- The marimo server reports `kernel-ready` again (browser tab closed and we want to take over)
- The user explicitly requests it via a new `<leader>mc` keymap ("reclaim connection")
- The browser tab is detected closed (poll `/health` for active session count, optional)

Critical files:

- `lua/neo-marimo/server.lua`: new function `release_ws(filepath)` that `jobstop`s `srv.ws_job_id` and clears `srv.ws_connected`.
- `lua/neo-marimo/server.lua`: modify `start_and_open` to call `release_ws` before `open_browser` if `config.options.server.share_with_browser == true` (new option, default `true`).
- New keymap `<leader>mc` ("reclaim"): calls `server.connect_ws(filepath, nb._on_ws_message)` again.

### 6.2 File watcher — pull browser edits into nvim

Marimo's browser saves the `.py` file when the user edits cells. We need to detect that and refresh the notebook view.

Implementation:

- `BufRead`-time: register a libuv `fs_event` watcher on the underlying `.py` path. Use `vim.uv.new_fs_event()`.
- On change, debounce 300ms, then:
  1. Check if our buffer is dirty — if yes, prompt before overwriting (rare; browser is normally the editor when our WS is released).
  2. Re-parse via the Python bridge.
  3. Diff parsed cells against `nb.cells` by ID. For each changed cell, replace its lines in-buffer via `nvim_buf_set_lines` (preserving cursor where possible).
  4. Re-render borders for any moved cells.

Critical files:

- New file `lua/neo-marimo/watcher.lua`: encapsulates the `fs_event` lifecycle.
- `lua/neo-marimo/sync.lua`: add `apply_remote_changes(nb, new_cells)` that does the cell-by-id diff and patches the buffer in place. Reuse `reload_from_file` as the fallback for major structural changes (cells added/removed).
- `lua/neo-marimo/init.lua`: start the watcher in `attach()`, stop it in the `BufWipeout` cleanup.

### 6.3 Send-side: push nvim edits to the live server

Currently the user's `:w` writes the `.py` file but the running marimo server is only watching the file via inotify-equivalent — there's a ~1s lag before it picks up. We can do better:

- After `sync.write_to_file` succeeds, also POST `/api/kernel/save` with the new cell codes if a server is running for this file. The endpoint exists (plan.md pending #3); calling it forces the server to reload immediately.
- For _interactive_ edits (no save yet), don't sync — the existing model of "save = sync" is correct. Marimo's browser editor also saves on edit; we mirror that.

Critical files:

- `lua/neo-marimo/server.lua`: new function `save_cells(filepath, cells)` that POSTs `/api/kernel/save`.
- `lua/neo-marimo/sync.lua`: call `server.save_cells` after successful `writefile` if server is running.

### 6.4 Implement remaining WS handlers via the dispatch table (5.3)

Phase 5's `ws_handlers` module gets two new entries:

- `update-cell-codes`: parse new cell codes from payload, call `sync.apply_remote_changes(nb, codes)`.
- `completed-run`: clear running-state spinners (no-op if `cell-op idle` already fired, which it usually does).

**Phase 6 verification:**

1. Edit a cell in nvim, `:w` → browser reloads instantly (within ~500ms).
2. Edit a cell in the browser → nvim notebook updates within ~500ms without manual `:MarimoReload`.
3. Open a notebook in nvim with `<leader>mo` → browser successfully connects (no "already connected" error).
4. After closing the browser tab, press `<leader>mc` → nvim reclaims the WS and resumes cell execution.

---

## Phase 7 — LSP & Hover (≈3–4 days)

**Goal:** pressing `K` shows actual documentation for symbols in the notebook buffer, just like in a regular `.py` file. Completion works too if the user has a completion plugin.

### 7.1 Marimo WS-based language features (primary)

Marimo's WS protocol exposes LSP-like ops: completion requests, hover requests, signature help. We use these when a server is connected.

Implementation:

- `python/ws_client.py`: add a `send` path. Currently the script only reads from the WS; we add stdin reading so Lua can write JSON commands and ws_client.py forwards them. (This was a "not yet implemented" item from plan.md.)
- `lua/neo-marimo/server.lua`: add `send_ws(filepath, msg)` that `chansend`s the JSON to `srv.ws_job_id`'s stdin.
- New file `lua/neo-marimo/lsp.lua`:
  ```lua
  function M.hover(bufnr)        -- bind to K
  function M.complete(bufnr)     -- bind to <C-x><C-o>
  function M.signature(bufnr)    -- bind to <C-k> in insert mode
  ```
  Each sends the appropriate WS op (marimo's actual op names confirmed via `:MarimoWsDebug` first) and renders the response in a floating window via `vim.lsp.util.open_floating_preview`.

### 7.2 Pyright shadow-buffer fallback

When no marimo server is running, fall back to a shadow buffer with the _real_ `.py` file contents (decorators included) attached to pyright/pylsp.

Implementation:

- `lua/neo-marimo/lsp.lua`: maintain a hidden scratch buffer per notebook (`vim.api.nvim_create_buf(false, true)`), populated with the output of `parser.generate_py(notebook.cells)` (the same function used by `sync.write_to_file`). Buffer is **not** displayed; it has the real filepath as its name so pyright attaches.
- On notebook-buffer change (debounced 500ms), regenerate the shadow buffer's contents.
- On `K`: translate cursor position from notebook buffer (cell-aware) to shadow buffer (full `.py` with wrappers). Map by computing how many decorator lines precede the current cell. Call `vim.lsp.buf.hover()` on the shadow buffer at the translated position; render the result in a floating window.

This is plumbing-heavy but isolated: the shadow buffer never appears in the user's window list, and the position translation is a single per-cell `+offset` calculation.

### 7.3 Glue: try-marimo-then-fall-back

`lsp.hover(bufnr)` first checks if `server.is_running(filepath) and srv.ws_connected`. If yes, route to marimo LSP. If no, route to pyright shadow. If pyright isn't installed either, show "no language server available" with a hint to start the marimo server.

Critical files for the whole phase:

- `python/ws_client.py` (bidirectional stdio)
- `lua/neo-marimo/server.lua` (`send_ws`)
- `lua/neo-marimo/lsp.lua` (new)
- `lua/neo-marimo/keymaps.lua` (bind `K`, `<C-k>` to `lsp.hover` / `lsp.signature`)

**Phase 7 verification:**

1. With marimo server running: `K` on a `pandas.DataFrame` symbol shows hover info from marimo's LSP.
2. With no marimo server: `K` on the same symbol falls back to pyright and still shows hover.
3. Completion via `<C-x><C-o>` works in both modes.
4. Hover in a `mo.md(...)` string returns nothing (rather than erroring) since the position is in a markdown context.

---

## Phase 8 — Rich Output (kitty graphics) (≈4–5 days)

**Goal:** markdown renders with treesitter highlights, plots and images show inline via kitty's graphics protocol, and basic marimo widgets render with interactive ASCII so the browser is no longer required for the common case.

### 8.1 Markdown rendering for `mo.md(...)` output

Currently `output.lua` strips HTML tags and shows plain text. Improvement: render the markdown source (not the HTML — marimo sends both via `text/markdown`) into virt_lines with treesitter highlights applied.

Implementation:

- Output renderer for `text/markdown`: split by lines, use `vim.treesitter.get_string_parser(line, "markdown")` to highlight inline.
- For headings, prefix with `▍ ` and bold the line. Lists get `• ` markers. Code blocks render as `▏ <code>` with syntax via treesitter.
- This is the standard render-markdown.nvim approach distilled into ~150 LOC; don't depend on the plugin itself.

### 8.2 Image rendering via kitty graphics

In kitty/WezTerm/Ghostty, images render natively via the kitty graphics protocol.

Implementation:

- Add `lua/neo-marimo/image.lua` that wraps the kitty graphics escape sequences:
  - Encode PNG bytes (base64), send `\x1b_Ga=T,f=100,...\x1b\\` escape.
  - For images, use `vim.api.nvim_open_win` to overlay a transparent float at the cell's output position; write the kitty escape to it.
- Register output renderer for `image/png`, `image/jpeg`, `image/svg+xml` (SVG → use `rsvg-convert` if available, fallback to placeholder).
- For matplotlib output (marimo sends `image/png` for `plt.show()` results), this just works.

Use the existing `snacks.image` or `image.nvim` API if the user has it installed (auto-detect via `pcall(require, "image")`); otherwise hand-roll the escape sequences.

### 8.3 Interactive widgets (ASCII placeholders + state sync)

Marimo widgets (`mo.ui.slider`, `mo.ui.button`, `mo.ui.text_area`) come through as `application/vnd.marimo+mime` with a JSON descriptor. Today we show `[marimo widget — open in browser]`. We can do much better:

- Render each widget type as an interactive ASCII control:
  - Slider: `[━━━●━━━] 0.42  (mo.ui.slider)` with current value
  - Button: `[ Click ]  (mo.ui.button)` highlighted, pressable with `<CR>`
  - Text: `[ "hello" ]  (mo.ui.text)` editable with `c` (change)
- Per-widget keymap: when cursor is on the widget's virt_line, `<CR>` or value-typing sends a WS update with the new value. Use the same `server.send_ws` from Phase 7.
- Output re-renders on response.

This won't cover every widget marimo ships, but it'll cover the top ~5 (slider, button, text, dropdown, checkbox) which is enough for most workflows.

### 8.4 DataFrame rendering improvements

The current ASCII table is fine but tops out at 5 rows. Add:

- A `<leader>mD` keymap that opens a side split with the full DataFrame rendered as a navigable table.
- Use `vim.api.nvim_open_win` with a fixed buffer; reuse existing ASCII renderer with no row cap.

**Phase 8 verification:**

1. `mo.md("# Hello")` cell output renders as a styled heading, not raw HTML.
2. A `plt.show()` cell renders the actual plot image inline below the cell.
3. A `slider = mo.ui.slider(0, 1, 0.01)` cell shows the slider as ASCII; pressing arrow keys on the slider line changes the value and the dependent cells re-run.
4. A DataFrame cell shows the ASCII table; `<leader>mD` opens a full-size view.

---

## What's deliberately _not_ in Phases 4–8

These belong to later phases (9+) and are listed so the foundations stay aligned:

- **RTC mode** (`MARIMO_RTC=true` + Yjs client) — replaces Phase 6's auto-disconnect with true simultaneous editing. Will land once Phase 6 proves the file-watch path is solid.
- **Cell interrupt / kill kernel** — single keymap + WS op once `send_ws` exists from Phase 7.
- **Variable explorer / outline** — separate floating window, depends on marimo's `variables` WS op.
- **Cell-dependency graph view** — depends on marimo's `cell-deps` data.
- **AI assistant integration** — out of scope; marimo's own AI is in the browser.

Each of these adds a new entry to either the output registry, the WS dispatch table, or the cell-type detector chain — never modifies the existing handlers. That's the payoff of the Phase 5 refactors.

---

## End-to-end verification across phases

After all five phases:

1. Open a marimo notebook in nvim → see styled cells with icons.
2. Type a multi-line `mo.md("""…""")` with Enters → save → file is valid.
3. `K` on a symbol → see hover info.
4. `<leader>mo` → browser opens; both editors stay in sync as you type.
5. A `plt.show()` cell shows the plot inline.
6. A `mo.ui.slider` cell is interactive from neovim.
7. Statusline shows `󰀘 marimo · 1 server · py #5/12`.
8. `:MarimoToggle` flips to raw `.py` view and back without losing server state.

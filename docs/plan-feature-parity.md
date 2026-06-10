---
id: plan-feature-parity
aliases: []
tags:
  - roadmap
  - planning
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

- **Hover / signature / goto-definition**: marimo doesn't expose these over the WS at all. The browser proxies them to a _separate_ LSP process (`pylsp`/`basedpyright`/`copilot`) running on a different port — see `_server/lsp.py`. We'd be reimplementing the same client-side LSP, just talking to marimo's bundled server. Not worth the extra moving piece.
- **Completion**: marimo _does_ have `POST /api/kernel/code_autocomplete` → kernel response over the WS as a `completion-result` notification. But `KIOSK_EXCLUDED_OPERATIONS` in `ws_message_loop.py` filters that notification out for kiosk consumers — and our default mode is kiosk (so the browser can co-edit). Promoting to main just to read completions would steal the slot back from the browser.

Decision: rely on the user's existing Python LSP (pyright/basedpyright/pylsp) through the shadow buffer (7.3). It gives all four LSP ops, has zero marimo-server coupling, and works whether or not a kernel is running.

If a follow-up phase wants marimo-kernel-aware completion as a _supplement_, the path is: connect a transient main-mode WS just for the completion exchange, parse the `completion-result` notification, merge with pyright results. Captured here so it's not lost.

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

| Mode | Default  | Action                                     |
| ---- | -------- | ------------------------------------------ |
| `n`  | `K`      | `lsp.hover()`                              |
| `i`  | `<C-k>`  | `lsp.signature()`                          |
| `n`  | `gd`     | `lsp.goto_definition()`                    |
| —    | omnifunc | `v:lua.neo_marimo_omnifunc` → `<C-x><C-o>` |

`lsp.is_in_markdown_string` suppresses requests on lines inside a `mo.md("""…""")` body — but the opener row (containing `mo.md(`) still gets routed so hover on `mo.md` works.

**Phase 7 verification:**

1. ✅ With pyright (or basedpyright/pylsp) running on the user's Python files: `K` on `pd.DataFrame` shows hover via the shadow buffer. End-to-end test with marimo notebook `test_db.py` + the user's mason-managed pyright returned the `duckdb` module docstring at the cursor position.
2. — The marimo-WS path was deferred (see 7.2). The shadow-buffer path works whether or not the kernel is running, so there's no "stop the server" scenario to test.
3. ✅ `<C-x><C-o>` (omnifunc → `neo_marimo_omnifunc`) drives completion via the shadow buffer. Tested against pyright on `os.<here>` — 311 items returned (`__name__`, `path`, `environ`, …).
4. ⚠ `gd` jumps within the _same cell_ because each cell is wrapped in its own `def __cell_N():`. Cross-cell goto-def is a known limitation of the shadow shape and would require either hoisting imports/definitions to module scope (extra static analysis) or mirroring marimo's codegen verbatim (brittle reverse-translation). Filed mentally as "could-improve, not blocking."
5. ✅ Hover inside `mo.md("""\n…\n""")` body returns nothing — `is_in_markdown_string` short-circuits before the LSP request.

### Post-Phase-7 hover investigation (2026-06-04)

User reported `K` on `np.array` "shows it as a function" in the notebook view while a regular `.py` "shows all the documentation". Captured pyright's actual hover response in both shapes (module-scope vs `def __cell_N():` wrapping) against the user's real project + venv:

- Module-scope: 1335-byte response, `(function)\ndef array(...)` signature overloads only.
- `def __cell_1():` wrapping: same 1335-byte response, byte-for-byte identical.
- Regular `.py` (no shadow, no wrap): same 1335-byte response.

So pyright returns the same content in all three. Numpy ships `.pyi` stubs without docstrings, so pyright has no prose to show — just the overloaded signatures. The user's perception of "more documentation" in regular `.py` is most likely the _same_ response perceived differently (or a stale pyright client serving cached state from before the shadow path moved).

What was actually clipping in the marimo view: I didn't set `max_height` on `open_floating_preview`, so the float defaulted to ~40% of `o.lines`. Pyright's overload response for a function like `numpy.array` runs ~50 lines, so the user saw the top few and assumed that was the whole response. Bumped `max_height` to 70% of editor height so the full hover is visible.

Conclusion: shadow shape is fine, no `def __cell_N():` rework needed. The blink.cmp source (#11–#13) can build on the current shape.

### Phase 7 follow-up: blink.cmp source ✅ SHIPPED (2026-06-04)

`lua/neo-marimo/blink.lua` is a blink.cmp source that wraps the existing shadow LSP path so completion fires inline in notebook cells (no need to hit `<C-x><C-o>`). Items are LSP `CompletionItem` objects passed through unchanged — blink consumes that shape natively.

User opts in via their blink.cmp config:

```lua
sources.default = { "lsp", "snippets", "buffer", "neo_marimo" },
sources.providers.neo_marimo = {
  name = "neo-marimo",
  module = "neo-marimo.blink",
},
```

Scoping: `:enabled()` checks `^marimo://` on the current buffer name, so the source has no effect on regular `.py` files. Trigger characters mirror pyright's set (`.`, `[`, `"`, `'`).

`:resolve()` routes `completionItem/resolve` back to the same client that served the item (stamped with `client_id` during `:get_completions`) so docstring expansion on hover-in-list goes to pyright, not whatever happens to be the first attached client.

---

## Phase 7.5 — Cell-tracking Stability ✅ SHIPPED (2026-06-10)

**Goal:** End the cell-corruption symptoms that surfaced after the markdown/widget commits (diagnosed 2026-06-08 → 2026-06-09): stacked `py #N` borders after multi-delete, code rendered without any cell border after `<leader>mn`, undo causing content to be glued onto the wrong cells, and the .py file losing code on save. The file on disk is the durable source of truth — right now we're corrupting it via drift in `nb.cells[].start_row/end_row`.

**Status:** Every subsection 7.5.1–7.5.8 shipped, including the architectural extmark migration (7.5.6) that the original plan flagged as optional. The integer `start_row/end_row` model has been fully replaced by extmark anchors; the only code that mutates those integers is now `sync_cells_from_extmarks` in `buffer.lua`, which reads them off the live extmarks. The manual shift math is gone from `actions.lua`, `keymaps.lua`, and `sync.lua`. See subsections below for commit hashes and the smart-p paste follow-up that emerged during 7.5.6 testing.

### Background

`nb.cells[].start_row/end_row` is a parallel data structure to the buffer, maintained via incremental updates from three uncoordinated paths:

- **`on_bytes_changed`** (`buffer.lua:310`) — vim-driven byte deltas, fires on every buffer mutation including undo.
- **Action handlers** (`actions.lua:60`, `keymaps.lua:86`) — our own buffer mutations, wrapped in `with_suppressed_bytes` so the byte tracker skips them. Each handler does manual `start_row += ±lc` math on subsequent cells.
- **Remote sync** (`sync.lua:170`) — applies WS / file-watcher updates from marimo to buffer + cells, also via manual shift math (`sync.lua:254-256`).

When any path drifts, all paths drift. `cell.code` is re-read from the buffer using the wrong offsets, so the wrong code gets written to disk on `:w`. The .py file becomes the lossy state, and reopening it shows fewer cells / merged code / orphaned outputs compared to what was on screen.

The fixes below replace each path's hand-rolled math with code that derives offsets from a single source of truth, then add a save-time safety net so the next regression is loud instead of silent.

### 7.5.1 Stop prune-on-create from killing fresh cells (ship first) ✅ `e0319ad`

`new_cell_below` (`actions.lua:75`) and `new_cell_above` (`actions.lua:97`) call `notebook.prune_phantoms(nb)` *before* `notebook.recompute_offsets(nb)`. `cell_mod.new` (`cell.lua:68`) returns `start_row = 0, end_row = 0` by default, so the just-inserted cell appears to overlap with whatever cell already lives at row 0. `prune_phantoms` removes it as the "empty overlapper." The inserted blank line is left orphaned in the buffer; subsequent typing on that line gets absorbed by whichever neighbor cell is adjacent. The same inverted call order exists in the delete keymap (`keymaps.lua:120`).

**Fix:** drop `prune_phantoms` from those three call sites. Keep it only in `on_bytes_changed`, where deltas can produce real phantoms.

**Verification:**
- `<leader>mn` repeatedly produces visible bordered cells. `:MarimoCheck` says OK after each.
- `<leader>md` deletes a cell; `:MarimoCheck` says OK.
- Sequence of mn / type / mn / type leaves every line inside a bordered cell.

### 7.5.2 Refuse to save when nb.cells doesn't match the buffer ✅ `c1b90c5`

`sync.write_to_file` writes the .py from `nb.cells[].code`. If `nb.cells` drifted away from the buffer, save commits the drift to disk. There's currently no check.

Add a pre-save validator in the `BufWriteCmd` handler (`init.lua:138`): walk each cell, compare `cell.code` to `nvim_buf_get_lines(bufnr, cell.start_row, cell.end_row+1)`. If any cell disagrees, abort the save with a notification naming the offending cell IDs and recommending `:MarimoCheck` or `:MarimoReload`. This turns silent disk corruption into a loud, recoverable failure mode.

**Verification:**
- Manually corrupt `cell.code` via Lua. `:w`. Save is aborted with a clear message.
- Normal save after typing in cells succeeds silently.

### 7.5.3 Make on_bytes_changed handle cross-cell deletes correctly ✅ `84b1a79`

`on_bytes_changed` (`buffer.lua:310`) assumes each delta affects exactly one cell. A multi-line delete that spans cells produces wrong offsets: the target cell's `end_row` shrinks past `start_row` (now prune-removed), but the shift loop applies the *full* delta to all subsequent cells instead of just the portion that affected rows past the deleted cells. Result: cells over-shift by the overflow amount and overlap whatever cell absorbed the deletion.

**Fix:**
- On `delta < 0`, compute `overflow = max(0, abs(delta) - (cell.end_row - cell.start_row + 1))`.
- The cell absorbs up to its own line count; the overflow propagates to `cell[idx+1]`.
- Repeat until `overflow == 0` or we run out of cells.
- `prune_phantoms` cleans up any cells fully consumed in this loop.

Insertion can't span cells (it happens at a single row), so no fix is needed for `delta > 0`.

**Verification:**
- `V3jd` spanning 3 separate 1-line cells leaves no overlap; `:MarimoCheck` says OK.
- `dd` on a single empty cell still cleanly removes it.
- Single-line delete inside a multi-line cell shrinks only that cell.

### 7.5.4 Replace manual shift math in `apply_remote_changes` ✅ `29f66de`

`sync.lua:254-256` has the same `for j = i+1, #nb.cells do start_row += delta` pattern that we already replaced with `recompute_offsets` in the delete/new_cell paths. Same compounding-drift potential.

**Fix:** after the in-place patch loop in `apply_remote_changes`, call `notebook.recompute_offsets(nb)` instead of the manual shifts.

**Verification:**
- Edit the notebook in the browser while it's open in nvim. After 5+ round-trips, `:MarimoCheck` stays OK and `nb.cells[].code` matches the buffer slice for each cell.

### 7.5.5 Detect undo and reconcile `<leader>md` ✅ `ca57049`

Undo of `<leader>md` is currently unrecoverable: vim restores the buffer rows, `on_bytes` fires (`delta > 0`), `cell_index_at_row` returns an adjacent cell, and the restored content gets glued onto a neighbor. The original cell's ID, options, and any server-side state are gone.

**Fix (two parts):**

(a) **Detect undo.** Track `b:changedtick` per notebook. When the next on_bytes batch arrives with a tick lower than the last seen tick, an undo just happened.

(b) **Soft-delete cells.** Change `<leader>md` to push the deleted cell onto `nb._undo_trash` — a small bounded ring buffer of recently-deleted cells with their full state (code, options, ID, original `start_row`). On detected undo, before processing the on_bytes batch, check: does the next delta's `start_row` + line count match any trashed cell? If yes, splice the trashed cell back into `nb.cells` at the right index and consume the corresponding delta as "delete done."

This isn't a complete undo system — only covers the dominant pain case (`<leader>md` then `u`). Full safety needs 7.5.6.

**Verification:**
- Create cells A, B, C. `<leader>md` on B. `u`. B is restored with its original ID, code matches the pre-delete state.
- Undo of plain typing inside a cell still works as today.
- Undo of multiple deletes in a row restores them in reverse order.

### 7.5.6 Architectural: extmark-based cell positions ✅ `e67c81c` (+ follow-ups `44b3847`, `46e0b4d`)

The root cause across all the above is that `cell.start_row` and `cell.end_row` are plain integers we mutate by hand from three call sites. nvim already ships the right primitive: **extmarks**. An extmark anchored at a buffer row stays anchored across inserts, deletes, and undo without our intervention.

**What shipped:**
- New namespace `ns_cell_anchor`, never wiped by border re-renders.
- Each cell gets a single `cell.start_mark_id` with `right_gravity = true`. We landed on start-only anchoring because the end of each cell is unambiguously "one row before the next cell's start" (or the last buffer line for the tail cell) — a parallel end-anchor would just be a second source of truth to keep in sync.
- `cell.start_row` / `cell.end_row` remain cached integers, but `sync_cells_from_extmarks` (`buffer.lua:40`) is now the only writer; it re-derives them from the live extmarks before every read path.
- `on_bytes_changed` collapses to `refresh_after_mutation` (sync → prune → sync → render). No delta math at all.
- The manual shift code in `actions.lua`, `keymaps.lua`, `sync.lua` is fully removed.
- `prune_phantoms` is retained as a defensive sweep for the case where a `dd` deletes the only line of a cell — vim's gravity collapses the anchor onto the next cell's, and prune drops the empty one before the validator runs.

**Follow-up fixes that surfaced while testing 7.5.6:**
- `44b3847` — `dd` on the only row of a cell left the anchor "alive but with end<start." Added a second-pass in `sync_cells_from_extmarks` that pushes such collapsed cells to undo trash so `u` can splice them back. Also introduced `refresh_after_mutation` as the shared post-mutation pipeline (action paths previously called `sync` without `prune`).
- `46e0b4d` — `vim.list_extend` mutates its first argument in place, so reading `#next_lines` *after* the call gave a doubled count and the moved cell's anchor landed too far down. Capture `next_count = #next_lines` and `start_at = cell.start_row` before `list_extend` in both `move_cell_down` and `move_cell_up`.

**Smart paste follow-up (`d3c4ca9`, then `61cc648`):** vanilla `p` after `<leader>mn` left a stray blank above the pasted line inside the fresh cell. The first attempt (`d3c4ca9`) rewrote to `Vp` for that case, but the single-line substitution dragged both right-gravity anchors past the new content and the paste ended up in the *previous* cell. Final fix (`61cc648`) does the substitution via `nvim_buf_set_lines` and immediately re-places this cell's anchor at the original row so it claims the pasted slice.

**Verification (passed):**
- All tests from 7.5.1–7.5.5 still pass.
- `:MarimoCheck` stays OK across heavy editing, undo, browser sync, and `<leader>mn` / `<leader>md` stress sequences.
- The manual shift code in `actions.lua`, `keymaps.lua`, `sync.lua` is fully removed without regression.

### 7.5.7 Cell ID stability across reload (closes `cell-op for unknown cell`) ✅ `54713e3`

`utils.generate_cell_id` mints fresh IDs on every `parser.parse_file` call (see comment at `sync.lua:181`). After `reload_from_file` fires (e.g. when the user accepts the "External change" prompt), client cell IDs no longer match what the marimo server is tracking. The server keeps sending `cell-op` messages keyed by the old IDs; `output.lua:377` logs each as `[neo-marimo] cell-op for unknown cell '...'`.

**Fix:** have the parser emit a stable ID per cell. Two viable shapes:

(a) **Persist the ID via a comment** above each `@app.cell`:
```python
# id: abc123
@app.cell
def _():
    ...
```
Parser reads the ID; if absent, mints one and writes it back on next save.

(b) **Derive the ID deterministically** from a hash of `(cell_position, normalized_code)`. Invisible to the user but fragile when two cells have identical code at the same position.

Recommend (a) with a config flag to disable the comments if the user finds them visually noisy.

**Shipped:** Option (a) via `python/bridge.py` (`extract_cell_ids` / `inject_cell_ids`). Each `@app.cell` now carries a `# id: XXXX` comment that round-trips through the parser/generator. The parser preserves the ID across reloads; cells without a comment get a fresh ID and the comment is written on the next save.

**Verification (passed):**
- Edit the file via browser, accept the External change prompt in nvim, run a cell. No "unknown cell" warnings appear.

### 7.5.8 Suppress "External change" prompt for our own writes ✅ `d789f7f` (+ follow-up `8f2ee45`)

`sync.is_writing(nb)` is supposed to gate the file watcher during our own saves, but marimo `--watch` re-writes the file when a dependent cell runs (e.g. after `b = 2000` triggers `a + b` to re-run), and that write lands outside our suppression window. The user sees an "External change" prompt mid-edit. Saying "Yes" triggers `reload_from_file`, which (a) wipes `nb.cells` and rebuilds with fresh IDs (compounding 7.5.7) and (b) hands the user a notebook that no longer reflects their unsaved edits.

**Fix:** compute a SHA1 of every file we write and every file the watcher reads. If the watcher's hash matches a recently-written hash, skip the prompt entirely.

**Shipped:** SHA256 (not SHA1) dedup via `vim.fn.sha256` — every write records the content hash, every watcher read compares against the ring of recent hashes. `8f2ee45` was the load-bearing follow-up: marimo `--watch` strips our `# id: XXXX` comments (Phase 7.5.7) before writing the file back, so the raw bytes never matched. The dedup now normalises by stripping id comments before hashing on both sides.

**Verification (passed):**
- Run a cell that triggers a dependent re-run. No prompt fires. Confirmed with a diagnostic loop watching `id_count` drop from N to 0 as marimo rewrote.
- An actually-external edit (e.g., `sed` from another terminal) still prompts as before.

---

### Execution order ✅ (historical)

Each step shipped as its own commit in the order below. The intermediate testing surfaced enough rough edges in the incremental approach that we ended up taking 7.5.6 (the architectural extmark migration) as well, even though it was flagged optional. The final ordering was: 7.5.1 → 7.5.2 → 7.5.3 → 7.5.4 → 7.5.5 → 7.5.7 → 7.5.8 → 7.5.6 → follow-up fixes (`44b3847`, `46e0b4d`, `d3c4ca9`, `61cc648`).

**Do not bundle 7.5.x into a single commit.** Each step verifies independently; bundling re-introduces the "what broke" guessing game that motivated this section. Phase 8 work should not start until 7.5.1–7.5.4 are shipped — Phase 8 adds output rendering paths that also touch `nb.cells[].code`, and they'd amplify any remaining drift.

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

| Widget        | Rendering                               | Key bindings (on the widget line)    |
| ------------- | --------------------------------------- | ------------------------------------ |
| `slider`      | `[━━━●━━━] 0.42`                        | `←`/`→` step, `=` set value (prompt) |
| `button`      | `[ Click ]`                             | `<CR>` to press                      |
| `text`        | `[ "hello" ]`                           | `c` to change (prompt)               |
| `text_area`   | Multi-line bordered box, edit on `<CR>` | `<CR>` to edit                       |
| `checkbox`    | `[x] label` / `[ ] label`               | `<CR>` to toggle                     |
| `dropdown`    | `[ value ▾ ]`                           | `<CR>` opens telescope-style picker  |
| `multiselect` | `[ a, b ▾ ]`                            | `<CR>` opens picker, `<Tab>` toggles |
| `number`      | `[ 42 ]`                                | `+`/`-` step, `=` set                |

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

## Nice to have's

- **Pretty Terminal Output** — optional toggle that can render things like numpy `array` in a nicer format, not sure this is worth it. Could even have 3d `arrays` are printed in asci as layers side by side, kind of faced diagonal to show that they are layered. Should more likely think about making the markdown text better. For example, bold looks great, but normal text is still a hard to read grey. Can I make it all more visual?

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

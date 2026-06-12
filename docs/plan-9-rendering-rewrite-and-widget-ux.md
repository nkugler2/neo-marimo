---
id: plan-9-rendering-rewrite-and-widget-ux
aliases: []
tags: []
---
# Phases 9–12 — Rendering correctness, widget UX, bug sweep, extensibility

## Why this plan exists

The plugin is feature-complete for daily use but three classes of problems remain:

1. **Widget/layout rendering is broken at the root.** The layout parser in
   `widgets.lua` was written against HTML shapes that marimo (0.19.4, the
   installed version) never emits. Tabs and accordions render nothing; cells
   that mix widgets with a table render only the table.
2. **Widget interaction is janky.** `<leader>mw` always opens a picker window
   (even for a single widget) and there is no visual indication of which
   widget you're acting on.
3. **No test coverage at all**, so regressions in the parse/render pipeline
   are invisible until a user notices. This is the "AI-coded, scared of
   hidden bugs" problem — the fix is a fixture corpus of _real_ marimo
   payloads with golden-output tests.

## Ground truth: what marimo 0.19.4 actually emits

Captured by running the installed marimo
(`~/.pyenv/versions/3.12.10/envs/MyMainTestingPython`) directly. **This is
the spec the renderer must match.** The current code's assumptions are wrong
in every row marked ✖.

| Construct                       | Real HTML                                                                                                                                          | Current parser assumes                                            |                                       |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- | ------------------------------------- |
| `mo.vstack([...])`              | `<div style='display: flex;...;flex-direction: column;...'>children</div>`                                                                         | `<marimo-vstack>` element                                         | ✖ never matches                       |
| `mo.hstack([...])`              | same div, `flex-direction: row`                                                                                                                    | `<marimo-hstack>` element                                         | ✖ never matches                       |
| `mo.ui.tabs({...})` / `mo.tabs` | `<marimo-ui-element object-id=…><marimo-tabs data-tabs='[json label htmls]' data-initial-value=…>` then one `<div data-kind='tab'>…</div>` per tab | `<marimo-tab-content data-label="…">` children                    | ✖ finds 0 tabs → renders **nothing**  |
| `mo.accordion({...})`           | `<marimo-accordion data-labels='[json]' data-multiple='false'><div>body</div>…`                                                                    | `<marimo-accordion-item data-label="…">`                          | ✖ finds 0 items → renders **nothing** |
| every `mo.ui.*`                 | wrapped in `<marimo-ui-element object-id='…' random-id='…'>`                                                                                       | handled via gsub id-hoisting hack                                 | ~ works but fragile                   |
| `mo.ui.table(df)`               | `<marimo-table data-data=…>` _anywhere_ in payload, incl. nested inside tabs                                                                       | "if payload contains `<marimo-table` → whole cell is a dataframe" | ✖ **the cell-4 bug**                  |
| `mo.ui.altair_chart`            | `<marimo-vega>`                                                                                                                                    | nothing                                                           | unknown-widget noise                  |
| `mo.ui.plotly`                  | `<marimo-plotly>`                                                                                                                                  | nothing                                                           | unknown-widget noise                  |
| `mo.ui.array`                   | `<marimo-dict>` + `<marimo-json-output>`                                                                                                           | nothing                                                           | unknown-widget noise                  |
| `mo.ui.data_explorer`           | `<marimo-data-explorer>`                                                                                                                           | nothing                                                           | unknown-widget noise                  |
| widget labels                   | triple-encoded: HTML-entity ⇒ JSON string ⇒ markdown-rendered HTML                                                                                 | handled (`clean_label`)                                           | ✔ keep                                |
| tab labels                      | `data-tabs` attr: JSON array of markdown-rendered HTML strings                                                                                     | n/a                                                               | reuse `clean_label` per entry         |

Other confirmed facts:

- `mo.tabs` **is** `mo.ui.tabs` (same function) — so every tabs cell goes
  through the ui-element wrapper path.
- Slider attrs: `data-start`, `data-stop`, `data-steps`, `data-initial-value`,
  `data-orientation`, `data-show-value`, `data-debounce`, `data-full-width`.
- Radio/dropdown carry `data-options` (JSON array) — the picker already
  decodes this correctly.

### Diagnosis of the two reported rendering bugs

- **"Cell 4 shows the dataframe from the previous cell"** — it's actually not
  the previous cell's output. Cell 4's `mo.ui.tabs` contains
  `ui_table = mo.ui.table(numbers_df)` in the "Tables" tab. `render_html`
  (`output.lua:113`) checks `dataframe.extract_from_html` **before** the
  widget/layout check, and that extractor matches `<marimo-table` anywhere in
  the payload — so the entire tabs output is replaced by an inline render of
  the embedded `numbers_df` table. Routing must be per-node, not per-payload.
- **"Lots of widgets aren't showing up"** — not a "too many widgets" limit.
  Tabs/accordion renderers look for child elements that don't exist (table
  above), so they return `{}` and the cell renders blank (or, when the
  ui-element wrapper defeats the layout match, everything is flattened
  through `parse_widgets` into a soup of placeholders including a bogus
  "[tabs]" widget).

---

## Phase 9 — Rendering correctness (root-cause fix) — **DONE (2026-06-11)**

> **Status:** shipped. 38 fixtures captured (`tests/fixtures/0.19/`,
> including `notebook_cell4.html` — the full cell-4 construct), `html.lua`
> parser with byte-exact round-trips over the whole corpus, `tree_render.lua`
> node walker, `widgets.lua` reduced to registry + renderers + set_value,
> `output.lua` routed per-node. 93 tests green via `make test`
> (`nvim -l tests/run.lua`). Bonus fixes that fell out: unlabeled widgets no
> longer display the literal string "null"; `widget_picker.commit` now passes
> `filepath` on re-render (was dropping virtual-file images); widget registry
> is cleared on every cell render so stale widgets don't linger in
> `:MarimoWidget` after a cell's output changes shape. Manual in-editor
> verification still requires push → pull into the vim.pack install path.

**Goal:** every cell in `notebooks/notebook.py` renders something sensible;
nested layouts (tabs containing tables containing widgets) render as a tree,
not via first-match-wins payload routing.

### 9.1 A real HTML node-tree parser — new `lua/neo-marimo/html.lua`

Replace the regex-chain parsing with a small tokenizer + tree builder
(~200 LOC). Node shape:

```lua
{ tag = "marimo-tabs", attrs = { ["data-tabs"] = "…" },
  children = { node | { text = "…" }, … } }
```

- Tokenize `<tag attrs>`, `</tag>`, text. Track void elements (`img`, `br`).
  Marimo's output is well-formed XML-ish HTML, so no error recovery needed —
  but unclosed tags must not infinite-loop (treat as self-closing on EOF).
- Move `decode_entities`, `parse_attrs`, `clean_label`,
  `parse_initial_value` here (single copy — today `widgets.lua` and
  `dataframe.lua` each have their own divergent entity decoders).
- Guard: payloads > ~2 MB (plotly figures) skip tree parsing → placeholder
  line. Parse is O(n) so this is belt-and-braces.

### 9.2 Node-walking renderer — rewrite routing in `output.lua` + `widgets.lua`

`render_html` becomes: parse to tree → `render_node(node, ctx)` dispatch:

| Node                                                                                                        | Renderer                                                                                                                                                                         |
| ----------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `marimo-ui-element`                                                                                         | set `ctx.object_id` from attr, recurse into children                                                                                                                             |
| flex `div` (style has `flex-direction: column/row`)                                                         | vstack / hstack over children (keep existing box-drawing renderers, feed them child nodes instead of regex slices)                                                               |
| `marimo-tabs`                                                                                               | labels ← `data-tabs` JSON + `clean_label`; bodies ← child `div[data-kind=tab]` nodes; render all tabs stacked with the existing labeled-divider style                            |
| `marimo-accordion`                                                                                          | labels ← `data-labels` JSON; bodies ← child divs                                                                                                                                 |
| `marimo-table`                                                                                              | `dataframe.render_inline` **scoped to this node** (serialize just this subtree for the existing attr extractor, or port the extractor to read attrs off the node) — fixes cell 4 |
| `marimo-slider/-checkbox/-text/…`                                                                           | existing per-type widget renderers, fed `ctx.object_id`; register in the per-cell widget registry                                                                                |
| `marimo-vega`, `marimo-plotly`, `marimo-data-explorer`, `marimo-dataframe`, `marimo-file`, `marimo-refresh` | one clean placeholder line: `[altair chart — <leader>mo to view in browser]` (still registered in the widget registry when they carry an object-id)                              |
| `marimo-dict` / `marimo-json-output`                                                                        | render the JSON value compactly (covers `mo.ui.array`)                                                                                                                           |
| `span.markdown` subtree                                                                                     | existing `markdown.render` on the subtree HTML                                                                                                                                   |
| `img` / `svg`                                                                                               | existing image extraction paths (data-URI, virtual file, inline svg)                                                                                                             |
| text node                                                                                                   | plain text line                                                                                                                                                                  |

Deletions: `UI_ELEMENT_PATTERN`/`inject_object_id` hack, `LAYOUT_PATTERN`,
`try_match_layout`, `split_layout_children`, `has_layout` string probes, the
"residual text" gsub dance at the bottom of `widgets.render`.

Keep: per-cell widget registry, `_value_overrides` semantics, `set_value`,
`describe`, all per-type ASCII renderers (they only change input plumbing).

Also update the `skip_cap` logic in `output.M.render` — after this rewrite
"has widgets/layout" is known from the parsed tree, not re-probed with
string.find on the raw payload.

### 9.3 Fixture corpus + test harness (the anti-"hidden bugs" investment)

- `tests/capture_fixtures.py` — script run with a marimo-equipped Python
  (`pyenv` env `MyMainTestingPython`); dumps `_repr_html_()` for every
  `mo.ui.*` widget, every layout, nested combos (tabs⊃vstack⊃slider,
  tabs⊃table — the cell-4 shape), `mo.md`, df HTML — one file per case under
  `tests/fixtures/*.html`. **Commit the fixtures** so tests run without
  Python/marimo.
- `tests/run.lua` — zero-dependency harness executed by
  `nvim -l tests/run.lua` (no plenary/mini.test needed): loads each fixture,
  runs the parse → virt_lines pipeline, asserts on structure (widget count,
  registry contents, no "[unknown]" lines, dataframe scoped correctly) and
  compares rendered text against golden `.txt` files where useful.
- A `make test` / `justfile` entry so it's one command.
- Re-capture fixtures when bumping supported marimo versions; version-stamp
  the fixture directory (`tests/fixtures/0.19/`).

### 9.4 Verification (manual, after push + pull per install workflow)

Every cell of `notebooks/notebook.py` checked against expected behavior:
cell 4 shows tabs with widgets + a 5-row table preview inside the Tables tab;
data_explorer/altair/plotly cells show clean placeholders; no blank outputs.

---

## Phase 10 — Widget interaction UX (focus cycling, smart picker, history & pins) — **DONE (2026-06-11)**

> **Status:** shipped. Focus model in `widgets.lua` (object-id primary,
> index fallback; ▸ marker via `MarimoWidgetFocused`), `]w`/`[w` cycling
> with cross-cell jumps, `<leader>mw` smart act (focused → direct, single →
> direct, multiple → ordered picker), `<leader>mW` full picker, digit 1-9
> selection, `<Tab>`/`<S-Tab>` tab-group cycling with footer, tab bodies
> gutter-prefixed (`│`) and widgets stamped with `w.tab` for grouping,
> `<leader>m.` last-edited shortcut, `<leader>mP` pin toggle +
> `<leader>mp` / `:MarimoWidgetPins` panel (stale pins greyed, `x` unpins),
> `+`/`-` nudging (data-step / data-steps aware, clamped, 150 ms debounced
> POST, builtin motion fallback), `widgets.set_value` converted to async
> with an optimistic ⟳ that a real cell-op status supersedes. 108 tests
> green via `make test` (15 new in `tests/spec/widget_ux_spec.lua`).
> Manual in-editor verification still requires push → pull into the
> vim.pack install path.

**Goal:** reduce keystrokes to reach any widget — no forced picker for single
widgets, number-key selection for multiple, tab-aware picker for layouts,
and a fast path back to recently-used or pinned widgets.

### 10.1 Focus model

- Per-buffer state: `{ cell_id, object_id }` of the focused widget (object_id
  survives re-renders; fall back to index if the id vanished).
- Renderers take a `focused` flag: focused widget gets a `▸ ` prefix and a
  new `MarimoWidgetFocused` highlight (e.g. reverse/bold) on its label.
  Re-render the affected cell(s) on focus change.

### 10.2 Keymaps (all configurable in `config.keymaps`)

| Key (default)                                                                               | Action                                                                                                                                                      |
| ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `]w` / `[w`                                                                                 | focus next/previous widget in the cell under the cursor (wraps; if cursor's cell has none, jump to next cell that has widgets)                              |
| `<leader>mw`                                                                                | **smart act**: if the cell under the cursor has exactly one widget, act on it directly with no menu; if it has multiple, open the ordered picker (see 10.3) |
| `<leader>mW`                                                                                | open the tab-aware picker unconditionally (full list view)                                                                                                  |
| `<leader>m.`                                                                                | re-act on the last-edited widget, wherever it lives (see 10.4)                                                                                              |
| `<leader>mp`                                                                                | open the pinned-widget panel (see 10.4)                                                                                                                     |
| `+` / `-` on focused slider/number/range (via `<leader>m+`-style or direct, decide at impl) | nudge by `data-step` (default 1), POST immediately, update override, re-render — no prompt                                                                  |
| checkbox/switch/button focused + act                                                        | toggle / press immediately, no prompt                                                                                                                       |

Acting on text/dropdown/multiselect keeps the existing `vim.ui.input` /
`vim.ui.select` prompts from `widget_picker.lua` — that part of the flow is
fine; it's the mandatory list window that's jank.

### 10.3 Picker improvements — ordered selection and tab awareness

**Ordered number selection (multiple widgets, no tabs)**

When a cell has more than one widget, `<leader>mw` opens a compact picker that
lists widgets in the order they appear in the rendered output (top to bottom,
left to right within hstacks). Each entry is prefixed with its 1-based index.
Pressing the corresponding digit (1–9) immediately acts on that widget without
navigating to it in the list. Example for a cell with three widgets:

```
  1  slider  speed         [0 – 100]
  2  dropdown  color       red
  3  checkbox  normalize   ✓
```

Pressing `2` opens the dropdown editor directly.

**Tab-aware picker (widgets inside `mo.ui.tabs`)**

When the cell contains tabs that hold widgets:

- The picker shows the current tab's widgets with number prefixes, same as
  above.
- A footer line reads `<tab> next tab · <S-tab> prev tab` and shows which tab
  is active (e.g. `Tab: Data [1/3]`).
- Pressing `<Tab>` / `<S-Tab>` cycles to the next/previous tab's widget list
  without closing the picker; the number prefix assignments reset per-tab.
- The rendered output (virtual lines) should already visually distinguish which
  tab each widget belongs to — update the tab renderer in Phase 9 if needed
  (e.g. prefix widget lines with a faint `│ Tab: Data` breadcrumb).

### 10.4 Widget history and pinning

**Last-edited shortcut**

- Track `last_widget = { bufnr, cell_id, object_id }` whenever a widget value
  is committed.
- `<leader>m.` jumps the cursor to that cell (if needed) and immediately opens
  the edit prompt for that widget. This makes iterating — e.g. tweaking a
  slider and watching output change — a single keystroke after the first edit.

**Pinned widgets panel**

- Users can "pin" any widget: while focused (or after acting on it), a keymap
  `<leader>mP` (capital P) toggles the pin for that widget. Pins are stored
  per-notebook file in a buffer-local (or persistent) list of
  `{ cell_id, object_id, label }` tuples.
- `<leader>mp` opens a dedicated picker showing only pinned widgets, regardless
  of which cell the cursor is in. The same ordered-number selection applies;
  acting on a pinned widget jumps to its cell, edits it, then returns focus to
  wherever the cursor was.
- Pins survive re-renders (matched by `object_id`). If a pinned widget's
  object-id disappears (cell deleted or rewritten), the entry is shown greyed
  out and can be unpinned.
- Pins are stored in a notebook-scoped state (e.g. a `pins` table keyed by
  `filepath`) so they reset when the notebook is closed.

### 10.5 Supporting fixes

- `widgets.set_value` is synchronous (`vim.system(...):wait()`,
  `widgets.lua:792`, up to 10 s UI freeze on a slow kernel). Convert to async
  callback form; show the cell status as `⟳` while the POST is in flight.
  Slider nudging makes this mandatory — repeated `+` presses must not stack
  blocking curls. Debounce nudges (~150 ms) so holding `+` coalesces.
- `widget_picker.commit` calls `output.render(nb.bufnr, cell)` **without the
  `filepath` arg** → a widget interaction in a cell whose output contains a
  virtual-file image would drop the image on re-render. Same in
  `output.clear`. Thread `nb.filepath` through (or better: store `filepath`
  on the cell render context once).

---

## Phase 11 — Bug sweep, perf, dead code — **DONE (2026-06-11)**

> **Status:** shipped, all 8 items. (1) `start_and_open` is now a fully
> async chain (timer-based /health polling replaces the blocking
> `vim.uv.sleep` loop, token fetch + WS-handshake wait are callback-based),
> `reclaim_ws` polls on a timer instead of `vim.wait`, `run_cells` /
> `instantiate` are async (`actions.lua` rolls the optimistic "queued"
> status back if the POST itself is rejected); parser bridge calls capped
> at 15 s, `pgrep`/`ps` at 2 s. (2) `WinResized`/`BufWinEnter` re-render
> all cell outputs (debounced 200 ms) after the border redraw. (3)
> `dataframe.lua`, `markdown.lua`, and `output.lua`'s strip-tags fallback
> all decode through `html.decode_entities` / `html.json_attr`. (4) every
> width in `dataframe.lua` (panel + inline preview) is display cells via
> `strdisplaywidth`/`pad_display`; `column_at_cursor` converts the byte
> cursor column to a display column so `s` sorts the right column on
> non-ASCII tables. (5) removed dead `buffer.render_cell_border`,
> `init.list_attached`, `markdown.render_markdown_source`, `output.clear`,
> `server.save_cells`, `watcher.stop_all` (kept `image.reset_backend`,
> `server.send_ws`, `server.is_any_running` — deliberate debug/integration
> hooks). (6) truncation hint reads the real keymaps from config and adds
> the dataframe-panel key when the payload holds a table. (7)
> `notebook.py` uses `add_params`. (8) new wrap pass in `output.lua`
> (`ui.wrap_output`, default on): every virt_line is hard-wrapped at the
> window text width — chunk-highlight-preserving, codepoint-safe,
> word-boundary-aware — so long markdown/stdout/table lines no longer
> vanish off the right edge; combined with (2) it re-wraps on resize.
> Bonus: `nb.filepath` threaded through the remaining `output.render`
> call sites (actions, toggle_output, :MarimoResetWidgets) so re-renders
> keep virtual-file images. 118 tests green via `make test` (8 new across
> `wrap_spec.lua`, `dataframe_spec.lua`, `output_spec.lua`). Manual
> in-editor verification still requires push → pull into the vim.pack
> install path.

Smaller items found during the audit, batched:

1. **Blocking `:wait()` audit** (`server.lua:60,130,233,765,773`,
   `parser.lua` ×3, `widgets.lua:792`). Convert the ones on interactive paths
   (widget set_value — done in 10.3; `server.lua` health/fetch calls invoked
   from keymaps) to async. Parser calls run on attach/save and can stay sync
   for now, but cap their timeouts.
2. **hstack column widths** are computed from window width at render time and
   go stale on resize → re-render outputs (debounced) on `WinResized`, like
   borders already do.
3. **Duplicate entity/JSON decoding code** in `dataframe.lua` vs
   `widgets.lua` — collapse onto `html.lua` (part of 9.1, listed here so it
   isn't forgotten if 9 lands piecemeal).
4. **`dataframe.column_at_cursor`** mixes byte columns and display columns —
   sorting breaks on non-ASCII headers/values. Use `strdisplaywidth`
   consistently.
5. Remove dead code after Phase 9: old layout regexes, `has_layout`,
   `inject_object_id`, plus any renderer no longer reachable.
6. `output.lua` `MAX_LINES` truncation message says "open in browser" — also
   mention `<leader>mt` toggle and `<leader>mD` when the payload is a table.
7. Re-check `notebooks/notebook.py` itself once rendering is fixed:
   `add_selection` is deprecated in altair 5 (warns on run) — switch to
   `add_params`; harmless but noisy.
8. **Output rendering issues** text with line lengths that are too long go off
   the right side of the screen, and can't be seen. True of things like markdown,
   dataframes, and just general standard out. There needs to be some way to fix
   this.

## Phase 12 — Extensibility & docs (make it usable by other people)

1. **README.md** (repo has none): install (lazy.nvim + vim.pack), config
   reference (generated from `config.lua` defaults), keymap table, supported
   marimo versions, terminal requirements (kitty/ghostty + image backend),
   GIF/screenshot of the notebook view.
2. **Architecture doc** (`docs/architecture.md`): module map + data flow
   (bridge/ws_client → server.lua → ws_handlers → output → renderer registry
   → widgets/dataframe/image/markdown), and the three extension points
   (renderer registry, WS dispatch table, cell-type detector chain) with a
   worked example "add a renderer for mimetype X".
3. **Public widget-renderer registration**: expose
   `widgets.register_renderer(name, fn)` (the table exists; make it API),
   document the virt_line chunk contract.
4. `:checkhealth` additions: image backend detected, marimo version probed
   and compared against the tested range, fixture-version note.
5. Stabilize the public API surface (what `require("neo-marimo")` exports)
   and mark internals with `_` consistently.

## Sequencing & effort

| Phase                               | Size          | Depends on                                    |
| ----------------------------------- | ------------- | --------------------------------------------- |
| 9.1 html.lua + 9.3 fixtures/harness | ~1–2 sessions | — (fixtures can be captured immediately)      |
| 9.2 node renderer rewrite           | ~1–2 sessions | 9.1                                           |
| 10 widget focus UX                  | ~1 session    | 9.2 (focus rendering hooks into new renderer) |
| 11 sweep                            | ~1 session    | mostly independent                            |
| 12 docs/extensibility               | ~1 session    | best after 9–10 settle the API                |

Recommended order: **9.3 fixtures first** (locks in ground truth), then 9.1 →
9.2 → 10 → 11 → 12. Verification requires push-to-GitHub + pull into the
vim.pack install path before testing in the real editor (per MYNOTES.md).

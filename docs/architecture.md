---
id: architecture
aliases: []
tags: []
---
# neo-marimo architecture

How the plugin is put together, how data flows from a marimo kernel to
virtual lines in a Neovim buffer, and where you can plug in your own code
without patching anything.

## The big picture

A marimo notebook is a plain `.py` file. neo-marimo never shows you that
file directly — it parses it into cells, renders the cells into a dedicated
`marimo://<path>` buffer with extmark borders, and writes valid marimo
Python back on `:w`. Running cells talks to a real `marimo edit` server
over HTTP + WebSocket, so reactivity (change a cell, dependents re-run)
behaves exactly like the browser.

```
            .py file on disk
                 │  parse (python/bridge.py)        write on :w (bridge.py generate)
                 ▼
   notebook.lua state  ◄──────────────  sync.lua  ◄──────────  BufWriteCmd
   { cells, offsets }
                 │ render
                 ▼
   buffer.lua  →  marimo:// buffer (borders, labels, anchors)
                 ▲
                 │ cell-op messages
   ws_handlers.lua  ◄─ stdout ─  python/ws_client.py  ◄─ WS ─  marimo server
                 │                                              ▲
                 ▼                                              │ spawn + HTTP POST
   output.lua (renderer registry)                          server.lua
                 │
                 ├─ tree_render.lua ─ html.lua (element tree)
                 │      ├─ widgets.lua     (sliders, dropdowns, …)
                 │      ├─ dataframe.lua   (tables, side panel)
                 │      ├─ markdown.lua    (mo.md output)
                 │      └─ image.lua       (plots, via image.nvim/snacks)
                 ▼
   extmark virt_lines under each cell
```

## Module map

### Entry and lifecycle

| Module | Role |
| --- | --- |
| `plugin/neo-marimo.lua` | Autoload entry: `BufReadPost` auto-attach, all `:Marimo*` user commands. |
| `init.lua` | Public API (`setup`, `attach`, `toggle`, extension-point registration). Owns the attach flow: parse → build state → create buffer → wire autocmds/watchers. |
| `config.lua` | Defaults + `setup()` merge. `config.options` is read everywhere else. |
| `health.lua` | `:checkhealth neo-marimo` — Python bridge, marimo version vs tested range, CLI, treesitter, image backend. |

### Notebook model and editing

| Module | Role |
| --- | --- |
| `parser.lua` | Thin sync wrapper around `python/bridge.py` (`parse`, `generate`, `check`). The bridge uses marimo's own loader, so parsing is exactly as permissive as marimo itself. |
| `notebook.lua` | The `nb` state table: `cells` list, `cell_by_id`, row offsets, undo-restore of deleted cells, offset validation. |
| `cell.lua` | Cell construction + the cell-type detector chain (python / markdown / sql / marimo widget). |
| `buffer.lua` | Everything extmark: cell borders, labels, anchors, row bookkeeping on `on_bytes` changes. |
| `sync.lua` | Save path (`BufWriteCmd` → bridge `generate` → disk) and the two inbound paths (file watcher reparse, `update-cell-codes` over WS) with drift validation. |
| `watcher.lua` | `fs_event` watcher on the `.py` for external edits (browser saves). |
| `actions.lua` | User-facing operations: run cell / run all, new cell, open in browser — including the save-before-run dance. |
| `keymaps.lua` | Binds everything in `config.keymaps` buffer-locally on the notebook buffer. |

### Kernel connection

| Module | Role |
| --- | --- |
| `server.lua` | One marimo server process per notebook: port probing, spawn, async `/health` polling, server-token fetch, HTTP POSTs (`run`, `instantiate`, `set_ui_element_value` lives in widgets.lua), WS connect/release/reclaim (browser handoff). |
| `python/ws_client.py` | Bridges the marimo WebSocket to stdio: newline-delimited JSON on stdout → Neovim, stdin → WS. Supports kiosk (observer) mode so nvim can coexist with a browser tab. |
| `ws_handlers.lua` | The WS dispatch table: op name → handler. Built-ins: `cell-op`, `kernel-ready`, `update-cell-ids`, `update-cell-codes`, `completed-run`, `neo_marimo_*` status messages. |

### Output rendering

| Module | Role |
| --- | --- |
| `output.lua` | Per-cell render driver. Owns the **mimetype renderer registry**, the status line (⟳/✓/✖), the MAX_LINES cap, the wrap pass, and `handle_cell_op`. |
| `html.lua` | Tokenizer + element-tree builder for marimo's HTML payloads. `serialize(node)` reconstructs the exact original substring of a subtree (byte-exact, fixture-tested), which is how subtrees feed the string-based renderers below. |
| `tree_render.lua` | Walks the element tree and routes per node: layouts (vstack/hstack/tabs/accordion), widgets, tables, markdown spans, images, placeholders for browser-only elements (vega/plotly/data-explorer). |
| `widgets.lua` | Widget registry per (bufnr, cell), value overrides, focus model (`]w`/`[w`, ▸ marker), pins, the **widget renderer registry**, and the async `set_value` POST. |
| `widget_picker.lua` | The interaction UI: smart act, ordered digit picker, tab-group cycling, pins panel, edit prompts, commit. |
| `dataframe.lua` | Dataresource-JSON + HTML-table extraction, inline 5-row preview, full side panel (`<leader>mD`, sortable). |
| `markdown.lua` | Unwraps marimo's `<span class="markdown">` wrapper, converts the HTML back to markdown, renders with structured highlights. |
| `image.lua` | Decodes base64 / data-URIs / inline SVG / server virtual files to temp files; draws via image.nvim or snacks.image with placement lifecycle management; text placeholder fallback. |

### LSP and completion

| Module | Role |
| --- | --- |
| `lsp.lua` | Hidden shadow buffer per notebook (all cells at module scope) so the user's Python LSP works in the notebook view: hover, goto-def, signature, omnifunc. |
| `blink.lua` | blink.cmp source wrapping the same completion driver. |

### Support

`highlights.lua` (groups + namespaces), `statusline.lua` (documented
statusline API), `utils.lua` (debounce, JSON, warn).

## Data flow: from "run cell" to pixels

1. `<leader>mr` → `actions.run_cell_at_cursor`: flush pending edits, save
   through the bridge, wait for marimo's `update-cell-ids` echo, then
   `server.run_cells` POSTs `/api/kernel/run` (async; the optimistic
   "queued" status rolls back if the POST is rejected).
2. The kernel executes and broadcasts `cell-op` messages over the WS.
   `ws_client.py` forwards each as one JSON line on stdout;
   `server.lua` parses lines and calls the `nb._on_ws_message` closure,
   which dispatches through `ws_handlers`.
3. The `cell-op` handler calls `output.handle_cell_op`: update
   `cell.status` / `cell.output` / `cell.console`, then `output.render`.
4. `output.render` clears the cell's old extmarks and widget registry,
   looks up a renderer by mimetype, and collects virt_lines:
   - `text/html` payloads with structure (marimo elements, tables, flex
     layouts) go through `tree_render.render` — parsed once by `html.lua`,
     rendered per node, widgets registered as they're encountered;
   - markdown wrappers, images, dataframes, plain text take their fast
     paths.
5. Lines are capped (unless the payload renders widgets/layouts), wrapped
   at the window text width, and attached as `virt_lines` on an extmark at
   the cell's last row. Window resizes re-render outputs (debounced) so
   hstack columns and wrapping stay correct.

Widget interaction inverts the flow: `widget_picker.commit` →
`widgets.set_value` POSTs `/api/kernel/set_ui_element_value` → marimo
re-runs dependent cells → their `cell-op` messages arrive as above. The
widget's *own* cell does not re-broadcast, which is why `widgets.lua`
keeps a per-object-id value override that re-renders consult.

## Extension points

There are four supported registries, all reachable from the top-level
module. Register at `setup()` time (or any time before the payload you
care about arrives). Registering an existing name **replaces** the
built-in, so you can also override default behavior.

```lua
local marimo = require("neo-marimo")
marimo.register_output_renderer(mime, fn)   -- output.lua registry
marimo.register_widget_renderer(name, fn)   -- widgets.lua registry
marimo.register_ws_handler(op, fn)          -- ws_handlers.lua dispatch
marimo.register_cell_detector(pred, type)   -- cell.lua detector chain
```

Anything not exported from `require("neo-marimo")` or documented here
(plus `statusline.lua`'s documented surface) is internal. Fields and
functions prefixed with `_` are private to their module and may change in
any commit.

### The virt_line chunk contract

Every renderer — output and widget alike — returns a **list of
virt_lines**. A virt_line is a list of `{text, hl_group}` chunks, exactly
the shape `nvim_buf_set_extmark`'s `virt_lines` option takes:

```lua
{
  -- one virt_line: chunks are concatenated on a single display row
  { { "  ", "MarimoOutputText" }, { "label", "MarimoWidgetLabel" } },
  -- second virt_line
  { { "  plain text", "MarimoOutputText" } },
}
```

Rules the pipeline relies on:

- Start lines with a two-space indent (`"  "`) to align with the built-in
  renderers.
- Don't hard-wrap yourself; `output.lua` wraps every line at the window
  text width after rendering (chunk highlights survive the wrap).
- Don't pad to a fixed width; display-cell math is done with
  `strdisplaywidth` downstream where needed.
- Return `{}` for "nothing to show". Returning text you've drawn by other
  means (like image placements) is how the image module suppresses
  placeholders.
- Useful highlight groups: `MarimoOutputText`, `MarimoOutputError`,
  `MarimoWidgetLabel`, `MarimoWidgetValue`, `MarimoWidgetFocused`,
  `Comment`. See `highlights.lua` for the full set.

### Worked example: a renderer for a new mimetype

Say a library emits `text/csv` and you want a tiny aligned preview
instead of the plain-text dump:

```lua
require("neo-marimo").register_output_renderer("text/csv", function(data)
  local lines = {}
  local n = 0
  for row in tostring(data):gmatch("[^\n]+") do
    n = n + 1
    if n > 6 then
      table.insert(lines, { { "  …", "Comment" } })
      break
    end
    local hl = (n == 1) and "MarimoWidgetLabel" or "MarimoOutputText"
    table.insert(lines, { { "  " .. row:gsub(",", " │ "), hl } })
  end
  return lines
end)
```

`fn(data, opts, mimetype)` — `data` is the CellOutput payload (string or
decoded JSON, depending on what marimo sent), `opts` is reserved, and
`mimetype` is the matched mimetype (useful for `image/*`-style prefix
patterns, registered as `register_output_renderer("image/*", fn)`).

### Worked example: replacing a widget renderer

Widget renderers draw the ASCII control for one `<marimo-{name}>`
element. The widget table `w` carries `name`, `object_id`, `value`
(initial value or the user's override), `options` (the decoded `data-*`
attributes — e.g. `start`/`stop`/`steps` for sliders), `label`, and
`focused`:

```lua
require("neo-marimo").register_widget_renderer("slider", function(w)
  local pct = 0
  local start = tonumber(w.options.start) or 0
  local stop = tonumber(w.options.stop) or 100
  if stop > start then pct = ((tonumber(w.value) or start) - start) / (stop - start) end
  local filled = math.floor(pct * 20 + 0.5)
  return { {
    { "  ", "MarimoOutputText" },
    { (w.label or "slider") .. " ", "MarimoWidgetLabel" },
    { string.rep("█", filled) .. string.rep("░", 20 - filled), "MarimoWidgetValue" },
    { " " .. tostring(w.value), "MarimoWidgetValue" },
  } }
end)
```

Names are the element suffix in snake_case: `<marimo-text-area>` →
`"text_area"`. Keep the leading two-space chunk as the *first* chunk —
the focus pass swaps it for `"▸ "` when the widget is focused, preserving
column alignment.

### Worked example: handling a WebSocket op

```lua
require("neo-marimo").register_ws_handler("completed-run", function(_, ctx)
  vim.notify("[marimo] " .. vim.fn.fnamemodify(ctx.nb.filepath, ":t") .. " is idle")
end)
```

`ctx` is `{ nb = <notebook state>, bufnr = <notebook buffer>, raw = <full message> }`.
Enable `:MarimoWsDebug` to log every op marimo sends and discover what's
available on your version.

## Testing

`make test` runs `nvim -l tests/run.lua` — a zero-dependency harness over
the fixture corpus in `tests/fixtures/<marimo-series>/` (real
`_repr_html_()` captures from marimo, committed so tests need no Python).
The specs in `tests/spec/` assert parse round-trips, render structure,
widget registry contents, wrapping, and dataframe extraction. When
bumping the supported marimo version, re-capture with `make fixtures`
(needs a marimo-equipped Python; see the `PYTHON` variable in the
Makefile), commit the new directory, and update the tested-series table
in `health.lua`.

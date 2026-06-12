# neo-marimo

Edit [marimo](https://marimo.io) notebooks in Neovim with a real notebook
experience: visually distinct cells, live reactive execution against a
marimo kernel, rendered outputs (markdown, dataframes, plots, widgets) as
virtual lines, and your existing Python LSP working inside cells.

<!-- TODO: screenshot/GIF of the notebook view (docs/assets/notebook.png) -->

marimo notebooks are plain `.py` files. neo-marimo parses the `@app.cell`
functions with marimo's own loader, presents them as bordered cells in a
dedicated buffer, and writes valid marimo Python back on `:w` — the file
on disk is always a normal notebook the browser (or a colleague) can open.

## Features

- **Notebook view** — each cell gets a colored border and a type label
  (`py`, `md`, `sql`, `mo`); markdown and SQL cells get injected syntax
  highlighting.
- **Reactive execution** — `<leader>mr` runs the cell under the cursor on
  a managed `marimo edit` server; dependent cells re-run and their outputs
  stream in live over the WebSocket, exactly like the browser.
- **Rendered output** — markdown (`mo.md`) with structured highlights,
  dataframes as aligned tables (5-row inline preview + a full sortable
  side panel on `<leader>mD`), matplotlib/PIL images inline via
  image.nvim or snacks.image, nested layouts (`mo.vstack`, `mo.hstack`,
  `mo.ui.tabs`, `mo.accordion`) rendered as a tree.
- **Interactive widgets** — sliders, dropdowns, checkboxes, text inputs
  and friends render as ASCII controls. Focus them with `]w`/`[w`, act
  with `<leader>mw`, nudge sliders with `<C-a>`/`<C-x>`, pin favorites,
  and re-edit the last one with `<leader>m.`. Value changes POST to the
  kernel and reactively re-run dependent cells.
- **LSP in cells** — hover, goto-definition, signature help, and
  completion are routed through a hidden shadow buffer, so pyright/
  basedpyright/ruff work in the notebook view without configuration. A
  [blink.cmp source](#completion) is included.
- **Browser handoff** — `<leader>mo` opens the same kernel in your
  browser; nvim drops to observer mode so both stay live, and
  `<leader>mc` reclaims the connection.
- **External-edit safe** — a file watcher and WS code-sync keep the view
  consistent when the browser (or another editor) saves the file.

## Requirements

- Neovim **0.11+**
- A Python interpreter with **marimo** installed (`pip install marimo`).
  Tested against the marimo **0.19** series — `:checkhealth neo-marimo`
  warns when your version is outside the fixture-tested range.
- `curl` on `$PATH` (kernel HTTP calls)
- Optional, for inline images/plots:
  [image.nvim](https://github.com/3rd/image.nvim) or
  [snacks.nvim](https://github.com/folke/snacks.nvim) with its `image`
  feature enabled, plus a graphics-capable terminal (kitty, ghostty,
  wezterm). Without these, images degrade to a file-path placeholder.
- Optional: nvim-treesitter with `python`, `markdown`, and `sql` parsers
  for syntax injection inside cells.

## Install

### lazy.nvim

```lua
{
  "nkugler2/neo-marimo",
  -- Load before *.py buffers are read so auto-detection sees the file.
  event = { "BufReadPre *.py", "BufNewFile *.py" },
  opts = {
    -- Python with marimo installed; REQUIRED if it's not your default python3
    python_path = "/path/to/venv/bin/python",
  },
}
```

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({ "https://github.com/nkugler2/neo-marimo" })
require("neo-marimo").setup({
  python_path = "/path/to/venv/bin/python",
})
```

`setup()` is optional — opening a marimo notebook auto-attaches with
defaults — but you must set `python_path` whenever marimo isn't
importable from plain `python3`.

## Quick start

```sh
nvim my_notebook.py        # auto-detected, opens in notebook view
```

Then:

1. `<leader>mr` — run the cell under the cursor (starts the server on
   first run). `<leader>mR` runs everything.
2. Edit code, `:w` to save back to the `.py`.
3. `]w` then `<leader>mw` — focus and interact with a widget.
4. `<leader>mt` to hide/show outputs, `<leader>mv` to flip to the raw
   `.py` view and back.

`:MarimoNew path/to/nb.py` scaffolds a fresh notebook.

## Configuration

All options with their defaults:

```lua
require("neo-marimo").setup({
  -- Python interpreter that has marimo installed
  python_path = "python3",
  -- The marimo CLI command (for opening in browser)
  marimo_cmd = "marimo",

  server = {
    host = "localhost",
    port = 2718,             -- first port probed; the next free one is used
    auto_start = true,
    -- Stop the marimo server when the notebook buffer is wiped (:bw).
    -- Default false so :MarimoToggle / :bd don't terminate a running kernel.
    stop_on_close = false,
    -- Release our WebSocket so the browser can take the single EDIT slot
    -- when you open the notebook there (we reconnect as an observer).
    share_with_browser = true,
    -- Watch the .py for external edits (browser saves, other editors).
    watch_file = true,
  },

  ui = {
    border_style = "rounded", -- "rounded" | "simple" | "none"
    show_cell_name = true,    -- function name in the border label
    show_cell_index = true,   -- cell number (#1, #2, …) in the border
    wrap_cells = true,        -- soft-wrap long code lines inside cells
    wrap_output = true,       -- hard-wrap output virt_lines at window width
    icons = true,             -- nerd-font glyphs (disable for plain ASCII)
  },

  keymaps = {
    -- set any to false to disable
    next_cell          = "]m",
    prev_cell          = "[m",
    new_cell_below     = "<leader>mn",
    new_cell_above     = "<leader>mN",
    delete_cell        = "<leader>md",
    move_cell_down     = "<leader>mJ",
    move_cell_up       = "<leader>mK",
    open_in_browser    = "<leader>mo",
    stop_server        = "<leader>mx",
    run_cell           = "<leader>mr",
    run_all            = "<leader>mR",
    interrupt          = "<leader>mi",
    restart_kernel     = "<leader>mX",
    toggle_output      = "<leader>mt",
    toggle_view        = "<leader>mv",
    reclaim_ws         = "<leader>mc",
    -- LSP (routed through the shadow buffer)
    hover              = "K",
    signature_help     = "<C-k>",   -- insert mode
    goto_definition    = "gd",
    completion         = true,      -- false leaves omnifunc alone
    -- data + widgets
    dataframe_panel    = "<leader>mD",
    widget_picker      = "<leader>mw",
    widget_picker_full = "<leader>mW",
    next_widget        = "]w",
    prev_widget        = "[w",
    widget_last        = "<leader>m.",
    widget_pin         = "<leader>mP",
    widget_pins        = "<leader>mp",
    widget_nudge_up    = "<C-a>",
    widget_nudge_down  = "<C-x>",
  },
})
```

## Keymaps

All buffer-local to the notebook view.

### Cells

| Key | Action |
| --- | --- |
| `]m` / `[m` | Next / previous cell |
| `<leader>mn` / `<leader>mN` | New cell below / above |
| `<leader>md` | Delete cell (undo with `u`) |
| `<leader>mJ` / `<leader>mK` | Move cell down / up |
| `<leader>mr` / `<leader>mR` | Run cell / run all |
| `<leader>mt` | Toggle output display for the cell |
| `<leader>mv` | Toggle notebook view ↔ raw `.py` (bound on both buffers) |

### Server & browser

| Key | Action |
| --- | --- |
| `<leader>mo` | Start the server (if needed) and open in browser |
| `<leader>mx` | Stop the server |
| `<leader>mi` | Interrupt the kernel (stop a runaway cell) |
| `<leader>mX` | Restart the kernel (outputs cleared; nothing re-runs until you ask) |
| `<leader>mc` | Reclaim the WebSocket from the browser |

### Widgets

| Key | Action |
| --- | --- |
| `]w` / `[w` | Focus next / previous widget (▸ marker; jumps across cells) |
| `<leader>mw` | Smart act: focused or single widget → edit directly; multiple → ordered picker (digits `1`–`9` act immediately, `<Tab>`/`<S-Tab>` cycle tab groups) |
| `<leader>mW` | Full tab-aware picker, unconditionally |
| `<C-a>` / `<C-x>` | Nudge the focused slider/number by its step (no prompt) |
| `<leader>m.` | Re-edit the last-edited widget, wherever it lives |
| `<leader>mP` | Pin / unpin the focused widget |
| `<leader>mp` | Panel of pinned widgets across the notebook |

### Data & LSP

| Key | Action |
| --- | --- |
| `<leader>mD` | Full DataFrame side panel (`s` sorts by column, `q` closes) |
| `K` | Hover |
| `gd` | Goto definition |
| `<C-k>` | Signature help (insert mode) |
| `<C-x><C-o>` | Omnifunc completion |

## Commands

| Command | Action |
| --- | --- |
| `:MarimoEdit` | Start the managed server and open the notebook in the browser (same as `<leader>mo`) |
| `:MarimoRun [all]` | Run the cell under the cursor, or every cell |
| `:MarimoInterrupt` | Interrupt the kernel's current execution |
| `:MarimoRestart` | Restart the kernel (clears outputs; nothing re-runs) |
| `:MarimoNewCell [above\|below]` | Insert a blank cell |
| `:MarimoStop` | Stop the server for this notebook |
| `:MarimoToggle` | Notebook view ↔ raw `.py` |
| `:MarimoReload` | Re-read the `.py` from disk and rebuild the view |
| `:MarimoNew [path]` | Create and open a new notebook |
| `:MarimoAttach` | Manually attach to the current buffer |
| `:MarimoServerList` | Interactive list of managed servers + system marimo processes (`<CR>` switch, `K` kill all) |
| `:MarimoKillAll` | Force-kill every marimo edit process on the system |
| `:MarimoWidget` | Widget picker for the cell under the cursor |
| `:MarimoWidgetPins` | Pinned-widgets panel |
| `:MarimoResetWidgets` | Drop cached widget value overrides and re-render |
| `:MarimoDataFramePanel` | Full DataFrame side panel |
| `:MarimoCheck` | Validate cell row bookkeeping against the buffer |
| `:MarimoInspectOutput` | Dump the cell's output mimetype/payload/widgets (debugging) |
| `:MarimoWsDebug [path\|off]` | Log every WebSocket message to a file |
| `:MarimoWsPing` | Send a no-op WS ping (pipe health check) |

## Completion

Built-in: `<C-x><C-o>` works out of the box (omnifunc is pointed at the
LSP-backed driver). blink.cmp users can get inline completion in cells:

```lua
require("blink.cmp").setup({
  sources = {
    default = { "lsp", "snippets", "buffer", "neo_marimo" },
    providers = {
      neo_marimo = { name = "neo-marimo", module = "neo-marimo.blink" },
    },
  },
})
```

The source auto-disables outside `marimo://` buffers.

## Statusline

```lua
-- lualine
sections = { lualine_x = { require("neo-marimo.statusline").component } }
```

`component()` returns e.g. `󰀘 marimo · 2 servers · py #3/12` (empty when
idle); `servers()` and `current_cell()` expose the raw pieces.

## Extending

Four registries let you add or replace behavior without forking — output
renderers by mimetype, widget renderers by element name, WebSocket op
handlers, and cell-type detectors:

```lua
require("neo-marimo").register_output_renderer("text/csv", function(data) … end)
require("neo-marimo").register_widget_renderer("slider", function(w) … end)
require("neo-marimo").register_ws_handler("completed-run", function(payload, ctx) … end)
require("neo-marimo").register_cell_detector(function(code) … end, "mytype")
```

See [docs/architecture.md](docs/architecture.md) for the module map, the
render pipeline, the virt_line chunk contract, and worked examples.

## Health & supported versions

`:checkhealth neo-marimo` verifies the Python bridge, the marimo version
against the fixture-tested range (currently the **0.19** series), the
marimo CLI, treesitter parsers, and the inline-image backend.

## Development

```sh
make test        # full suite: nvim -l tests/run.lua
make fixtures    # re-capture the marimo HTML corpus (needs a marimo python)
make dev-link    # symlink the vim.pack install path to this working copy
make dev-unlink  # restore the previous (git-tracked) install
```

`make dev-link` makes local edits live on the next nvim restart — no
commit/push/pull loop while developing. The previous install is preserved
and `make dev-unlink` puts it back.

Rendering is golden-tested against real marimo `_repr_html_()` captures
committed under `tests/fixtures/<series>/`. The editing core (extmark cell
tracking, undo restore, remote patching) is integration-tested headlessly in
`tests/spec/editing_spec.lua`; the Python bridge has marimo-gated round-trip
specs that self-skip when no marimo-equipped python is available
(`NEO_MARIMO_TEST_PYTHON` selects the interpreter — `make test` points it at
the `PYTHON` variable). CI runs everything on nvim stable and nightly via
`.github/workflows/test.yml`.

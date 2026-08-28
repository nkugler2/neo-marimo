# neo-marimo: Neovim Plugin for Marimo Notebooks

## Context

The user wants to edit Marimo notebooks inside Neovim with a notebook-like visual experience. Marimo saves notebooks as pure Python `.py` files with `@app.cell` decorated functions. The plugin needs to parse those files, display cells as visually distinct regions with type-aware syntax highlighting, allow editing that round-trips back to valid Marimo Python, and provide a keyboard shortcut to open the notebook in the real Marimo browser editor. Cell execution with inline output is desired but secondary to the editing experience.

**Plugin manager**: vim.pack (Neovim 0.12+ built-in). No lazy.nvim spec format needed.

---

## Architecture Decision: Notebook Buffer + Extmarks

The plugin creates a **custom buffer** that shows only raw cell code lines (no decorator boilerplate). Cell borders and output are rendered entirely as **virtual lines** via `nvim_buf_set_extmark`, so they occupy no buffer rows and don't interfere with cursor position or line-number-based operations. Two-way sync between the buffer and the underlying `.py` file happens on save.

This is better than decorating the raw `.py` file because it avoids complex row-offset mapping that breaks when the `@app.cell` wrappers shift.

---

## Directory Structure

```
neo-marimo/
├── plugin/
│   └── neo-marimo.lua          # BufReadPost detection, user commands
├── lua/
│   └── neo-marimo/
│       ├── init.lua            # setup(opts), attach(bufnr)
│       ├── config.lua          # default config table
│       ├── cell.lua            # cell data model, detect_type()
│       ├── notebook.lua        # notebook state: cell list, dirty tracking
│       ├── buffer.lua          # buffer creation, rendering, extmarks
│       ├── sync.lua            # buffer <-> .py file two-way sync
│       ├── parser.lua          # Lua wrapper calling Python bridge via vim.system
│       ├── server.lua          # Marimo HTTP + WebSocket client
│       ├── output.lua          # cell output rendering as virt_lines
│       ├── highlights.lua      # highlight groups, namespace creation
│       ├── keymaps.lua         # buffer-local keymaps
│       └── utils.lua           # debounce, cell ID generation, JSON helpers
├── queries/
│   └── python/
│       └── injections.scm      # TreeSitter injection: markdown in mo.md(), SQL in mo.sql()
├── python/
│   ├── bridge.py               # parse / generate subcommands using marimo's own _ast
│   └── ws_client.py            # async WebSocket client (stdin/stdout JSON protocol)
└── doc/
    └── neo-marimo.txt          # vimdoc help
```

---

## Implementation Plan

### Phase 1: Core Editor (MVP - editor experience)

**Goal**: Open any Marimo `.py` file in a notebook buffer with visual cell borders and per-type syntax highlighting.

#### Step 1.1 - Project skeleton and detection
- Create the directory structure above.
- `plugin/neo-marimo.lua`: register `BufReadPost` that reads the first 500 bytes of a `.py` file, checks for `app = marimo.App()` or `marimo.App(`, and if found calls `require("neo-marimo").attach(vim.fn.bufnr())`.
- Define user commands: `:MarimoEdit` (open in browser), `:MarimoRun` (run cell), `:MarimoNew` (new cell).

#### Step 1.2 - Python bridge (parse)
`python/bridge.py parse <filepath>` → stdout JSON:
```python
from marimo._ast.parse import parse_notebook
# parse_notebook returns a NotebookSerializationV1
# Extract: cells[].name, cells[].code, cells[].options
# Output JSON: {"cells": [...], "version": "...", "app_options": {...}}
```
The exact marimo internals to use: `marimo._ast.parse.parse_notebook()` which returns the `NotebookSerializationV1` IR with a `.cells` list of `CellDef` objects having `.code`, `.name`, `.config`.

#### Step 1.3 - Cell data model (`cell.lua`)
```lua
-- Cell table shape:
{
  id = "Hbol",        -- Marimo CellId_t (4-char)
  name = "_",         -- function name
  code = "x = 1",    -- raw code (no wrapper)
  type = "python",    -- "python" | "markdown" | "sql"
  config = {},        -- {disabled, hide_code, column}
  start_row = 0,      -- 0-indexed buffer row (inclusive)
  end_row = 0,        -- 0-indexed buffer row (inclusive)
  output = nil,       -- last output or nil
  status = "idle",    -- "idle" | "running" | "queued" | "error"
  border_ns_ids = {}, -- extmark IDs for top/bottom borders
}
```
`detect_type(code)`: returns "markdown" if code matches `^%s*mo%.md%(`, "sql" if matches `mo%.sql%(`, else "python".

#### Step 1.4 - Buffer rendering (`buffer.lua`)
- `create_notebook_buffer(notebook)` → bufnr:
  - `vim.api.nvim_create_buf(false, true)` — scratch buf
  - Set `buftype = "acwrite"`, `filetype = "python"`, `modifiable = true`, `bufhidden = "wipe"`
  - Write all cell code lines contiguously (no separator lines)
  - Call `render_borders(bufnr, notebook)`
- `render_borders(bufnr, notebook)`:
  - For each cell, place two extmarks in `ns_border`:
    - **Top border** at `start_row` with `virt_lines_above = true`:
      ```
      ╭─── [python] my_cell ────────────────────────────╮
      ```
      Using highlight `MarimoCellPythonBorder` / `MarimoCellMarkdownBorder` / `MarimoCellSQLBorder`
    - **Bottom border** at `end_row` with `virt_lines = {{...}}`:
      ```
      ╰─────────────────────────────────────────────────╯
      ```
  - Virtual lines don't occupy buffer rows — cursor positions are unaffected

#### Step 1.5 - Row offset tracking (`sync.lua`)
Critical invariant: cells are contiguous in the buffer, no separator rows. Cell `i` occupies rows `[cell[i].start_row, cell[i].end_row]`. Cell `i+1` starts at `cell[i].end_row + 1`.

On `TextChanged` (debounced 300ms):
1. Get cursor row → find which cell contains it
2. Compare that cell's current line count to stored count
3. Apply delta to `end_row` of that cell and `start_row`/`end_row` of all subsequent cells
4. Re-render borders at updated positions
5. Mark notebook dirty

#### Step 1.6 - Highlights (`highlights.lua`)
```lua
vim.api.nvim_set_hl(0, "MarimoCellPythonBorder",   { fg = "#7E9CD8", bold = true })
vim.api.nvim_set_hl(0, "MarimoCellMarkdownBorder",  { fg = "#76946A", bold = true })
vim.api.nvim_set_hl(0, "MarimoCellSQLBorder",       { fg = "#957FB8", bold = true })
vim.api.nvim_set_hl(0, "MarimoOutputText",          { link = "Comment" })
vim.api.nvim_set_hl(0, "MarimoOutputError",         { fg = "#E82424" })
vim.api.nvim_set_hl(0, "MarimoStatusRunning",       { fg = "#FFA066" })
```
Namespaces: `ns_border = vim.api.nvim_create_namespace("neo_marimo_border")`, `ns_output = vim.api.nvim_create_namespace("neo_marimo_output")`.

#### Step 1.7 - Keymaps (`keymaps.lua`)
Buffer-local keymaps (configurable):
```
<leader>mn  - New cell below
<leader>mN  - New cell above
<leader>md  - Delete cell
<leader>mJ  - Move cell down
<leader>mK  - Move cell up
<leader>mo  - Open in browser (marimo edit <file>)
<leader>mr  - Run cell (Phase 2)
<leader>mR  - Run all (Phase 2)
]m          - Next cell
[m          - Previous cell
```

**Open in browser**: `vim.fn.jobstart({"marimo", "edit", notebook.filepath}, {detach = true})`

**Phase 1 milestone**: `nvim notebook.py` opens a notebook buffer with visual cell borders, cell type labels, and working cell CRUD keymaps.

---

### Phase 2: Save Sync and TreeSitter Injection

#### Step 2.1 - Write back to .py file
`BufWriteCmd` autocmd on the notebook buffer:
1. `sync.recompute_offsets(bufnr, notebook)` — recalculate all row boundaries
2. For each cell: extract lines from buffer, set `cell.code`
3. Call `parser.generate_py(notebook.cells, notebook.filepath)` → calls `python/bridge.py generate`
4. Write result to `notebook.filepath` with `vim.fn.writefile()`
5. Set modified = false

`python/bridge.py generate` (stdin: JSON with cells list → stdout: .py source):
- Use `marimo._ast.codegen.generate_filecontents(codes, names, cell_configs=configs)` if the function exists
- Fallback: use `marimo._ast.codegen.to_functiondef` per cell and assemble the file manually with the standard header
- The goal is always-valid marimo Python that round-trips through `parse_notebook` correctly

#### Step 2.2 - TreeSitter language injection
`queries/python/injections.scm` — must start with `;; extends`:
```scheme
;; extends

;; Markdown inside mo.md("..." or r"..." or """...""")
(call
  function: (attribute
    object: (identifier) @_mo (#eq? @_mo "mo")
    attribute: (identifier) @_fn (#eq? @_fn "md"))
  arguments: (argument_list
    (string (string_content) @injection.content))
  (#set! injection.language "markdown")
  (#set! injection.include-children))

;; SQL inside mo.sql("..." or f"...")
(call
  function: (attribute
    object: (identifier) @_mo (#eq? @_mo "mo")
    attribute: (identifier) @_fn (#eq? @_fn "sql"))
  arguments: (argument_list
    (string (string_content) @injection.content))
  (#set! injection.language "sql"))
```
Add plugin root to rtp in `plugin/neo-marimo.lua` so nvim-treesitter picks up the query file:
```lua
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))
```

**Phase 2 milestone**: Edits in the notebook buffer save back to valid `.py` files. `mo.md()` strings show markdown highlighting, `mo.sql()` strings show SQL highlighting.

---

### Phase 3: Marimo Server Connection and Cell Execution

**Goal**: Run cells and see text output inline without leaving Neovim.

#### Step 3.1 - Server management (`server.lua`)
HTTP via `vim.system` + curl (no external Lua HTTP lib needed):
```lua
local function http_post(url, session_id, body)
  return vim.system({
    "curl", "-s", "-X", "POST", url,
    "-H", "Content-Type: application/json",
    "-H", "Marimo-Session-Id: " .. session_id,
    "-d", vim.json.encode(body),
  }, { text = true }):wait()
end
```

`start_if_needed(filepath)`: check `http://localhost:2718/health`. If not running, launch `marimo edit --headless {filepath}` via `vim.fn.jobstart`. Poll every 500ms (max 10s) for the server to respond.

WebSocket via `python/ws_client.py` (persistent subprocess):
- `vim.fn.jobstart({"python3", ws_client_path, server_url, session_id, filepath})`
- `on_stdout`: parse JSON lines, `vim.schedule` → dispatch to message handlers
- `send(cmd)`: `vim.fn.chansend(job_id, vim.json.encode(cmd) .. "\n")`

#### Step 3.2 - WebSocket protocol
Connection URL: `ws://localhost:2718/ws?session_id={uuid}&file={filepath}`

Sequence:
1. Connect → server sends `{"op": "kernel-ready", ...}`
2. POST `/api/kernel/instantiate` with `{"objectIds": [], "values": [], "autoRun": true}` and `Marimo-Session-Id` header
3. WS receives `{"op": "cell-op", "cell_id": "...", "status": "running"}` then `{"op": "cell-op", "output": {...}, "status": "idle"}`

Execute cell: POST `/api/kernel/run` with `{"cellIds": [...], "codes": [...]}`

Save: POST `/api/kernel/save` with `{"cellIds": [...], "codes": [...], "names": [...], "configs": [...], "filename": "..."}`

Key WS ops to handle: `kernel-ready`, `cell-op`, `completed-run`, `update-cell-codes`

#### Step 3.3 - Output rendering (`output.lua`)
Place output as `virt_lines` at `cell.end_row` (after the bottom border, using lower priority):
- `text/plain` → split by newlines, each line = one virt_line with `MarimoOutputText`
- `application/vnd.marimo+error` → error lines with `MarimoOutputError`
- DataFrames (`application/vnd.dataresource+json`) → render compact ASCII table (5 rows max)
- Images → `"[image - open in browser]"` placeholder

`toggle_output` keymap (`<leader>mt`) hides/shows the output virt_lines for the current cell.

**Phase 3 milestone**: `<leader>mr` runs a cell and shows text output below it. `<leader>mo` opens in browser for widget-heavy output.

---

## Key Technical Details

### Python bridge calling convention
```lua
-- parser.lua
function M.parse_file(filepath)
  local r = vim.system({ config.python_path, bridge_path, "parse", filepath }, { text = true }):wait()
  if r.code ~= 0 then error("bridge: " .. r.stderr) end
  return vim.json.decode(r.stdout)
end

function M.generate_py(cells, filepath)
  local r = vim.system(
    { config.python_path, bridge_path, "generate" },
    { text = true, stdin = vim.json.encode({ cells = cells, filepath = filepath }) }
  ):wait()
  if r.code ~= 0 then error("bridge: " .. r.stderr) end
  return r.stdout
end
```

### Default config
```lua
{
  python_path = "python3",
  marimo_cmd = "marimo",
  server = { host = "localhost", port = 2718, auto_start = true },
  ui = { border_style = "rounded" },  -- or "simple" (─│) or "none"
  keymaps = { ... },
}
```

### vim.pack usage
The user uses vim.pack (Neovim 0.12+). The plugin will be added as:
```lua
vim.pack.add("https://github.com/noahkugler/neo-marimo")
```
No lazy.nvim spec table needed. The plugin should set up its `plugin/` file to be sourced automatically on rtp.

---

## Verification

**Phase 1**:
1. Open an existing Marimo `.py` file in Neovim → should open in notebook buffer with colored cell borders
2. Navigate cells with `]m` / `[m`
3. Add a cell with `<leader>mn`, delete with `<leader>md`
4. Verify `mo.md("""# Hello""")` shows markdown highlighting inside the string
5. Press `<leader>mo` → browser opens with the notebook

**Phase 2**:
1. Edit code in a cell → save with `:w` → `cat notebook.py` shows valid marimo Python
2. Add/delete cells → save → verify the `.py` file has correct number of `@app.cell` functions
3. Verify round-trip: open in marimo browser, edit there, open in neovim → shows changes

**Phase 3**:
1. `<leader>mr` on a cell with `x = 1 + 1` → shows `2` below the cell
2. `<leader>mr` on a cell with an error → shows error message with red highlight
3. `<leader>mR` runs all cells → outputs appear for all

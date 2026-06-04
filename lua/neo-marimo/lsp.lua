-- LSP integration for neo-marimo notebooks.
--
-- The notebook buffer (marimo://...) hides marimo's @app.cell decorators
-- and isn't visible to whatever Python LSP the user has configured. To
-- restore hover / completion / signature / goto-def inside the notebook
-- view, we keep a hidden shadow buffer per notebook and route LSP
-- requests against it.
--
-- Shadow buffer shape (built by build_shadow_text):
--   #@cell 0 [py]
--   def __cell_0():
--       <cell-0 code, indented +4>
--
--   #@cell 1 [py]
--   def __cell_1():
--       <cell-1 code, indented +4>
--
-- Each cell becomes a function so `return` statements (common in marimo
-- cells) parse cleanly. The +4 indent shift is applied when translating
-- cursor positions. Top-level imports inside a cell don't propagate
-- across cell boundaries — that's a known compromise; the alternative
-- (parsing each cell's imports and hoisting them) would mean rebuilding
-- marimo's static-analysis pass in Lua. Hover, signature, and completion
-- for stdlib + already-imported-in-cell symbols all work; only
-- cross-cell goto-def is degraded.
--
-- We do *not* try to mirror marimo's exact codegen (decorators,
-- `app._unparsable_cell(...)`, etc.) — that shape is brittle to translate
-- back into notebook coordinates because different cells get wrapped
-- differently. The simpler `def __cell_N():` shape gives a one-to-one
-- cell→row mapping that we can invert reliably.

local M = {}

-- Hidden shadow buffer state, keyed by source filepath.
--   {
--     bufnr            = number,    -- the shadow scratch buffer
--     cell_offsets     = { ... },   -- per-cell { shadow_start_row, col_shift }
--     last_shadow_text = string,    -- the last text we wrote to the shadow,
--                                   -- so we can skip no-op rewrites
--   }
M._shadows = {}

-- Drop empty strings from the start and end of a list of lines.
-- Replaces `vim.lsp.util.trim_empty_lines`, which emits a deprecation
-- warning on first use in nvim 0.12 ("vim.lsp.util.trim_empty_lines() is
-- deprecated"). Keeps interior blank lines untouched.
local function trim_empty_lines(lines)
  local first, last = 1, #lines
  while first <= last and (lines[first] == nil or lines[first] == "") do
    first = first + 1
  end
  while last >= first and (lines[last] == nil or lines[last] == "") do
    last = last - 1
  end
  if first == 1 and last == #lines then return lines end
  local out = {}
  for i = first, last do
    table.insert(out, lines[i])
  end
  return out
end

-- Indent each non-empty line in `code` by 4 spaces. Used so cell code
-- nests inside the `def __cell_N():` wrapper without breaking on blank
-- lines (pyright is happy with mixed indentation as long as non-blanks
-- are consistent).
local function indent4(code)
  if code == "" then return "" end
  local out = {}
  for line in (code .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" then
      table.insert(out, "")
    else
      table.insert(out, "    " .. line)
    end
  end
  -- Trim the trailing empty string from the gmatch tail.
  if out[#out] == "" then table.remove(out) end
  return table.concat(out, "\n")
end

-- Build the shadow text and a per-cell offset table from the current
-- notebook cells. Returns (text, offsets) where offsets[i] is
-- { shadow_start_row = N, col_shift = 4 } — the 0-indexed shadow row where
-- cell i's code begins, and the column adjustment applied to that cell.
--
-- shadow row layout per cell:
--   row K:     #@cell i [type]    ← marker (for debug grepping)
--   row K+1:   def __cell_i():
--   row K+2..: indented cell code
--   row K+N+2: <blank separator>
local function build_shadow_text(nb)
  local lines = {}
  local offsets = {}

  for i, cell in ipairs(nb.cells) do
    local marker = string.format("#@cell %d [%s]", i, cell.type or "py")
    table.insert(lines, marker)
    table.insert(lines, string.format("def __cell_%d():", i))

    local code_start_row = #lines  -- 0-indexed row of the first cell-code line
    offsets[i] = {
      shadow_start_row = code_start_row,
      col_shift = 4,
    }

    local code = cell.code or ""
    if code == "" then
      table.insert(lines, "    pass")
    else
      local indented = indent4(code)
      for line in (indented .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
      end
      -- Strip the trailing empty produced by the gmatch tail on a final \n.
      if lines[#lines] == "" and not code:match("\n$") then
        table.remove(lines)
      end
    end

    table.insert(lines, "")  -- blank separator
  end

  return table.concat(lines, "\n"), offsets
end

-- Best-effort: attach every existing Python LSP client to `bufnr`. Most
-- users have a plugin (or `vim.lsp.enable`) that has already started
-- pyright/basedpyright/pylsp/ruff on some other Python buffer; we piggy-
-- back on that rather than rolling our own start config.
--
-- We attach ALL matching clients rather than the first one — common
-- setups run multiple language servers concurrently (e.g. pyright for
-- hover/types + ruff for diagnostics). Attaching only the first risks
-- picking the one without the capability we need (ruff without hover,
-- pyright without diagnostics, etc.).
--
-- If nothing is currently running, fire a FileType=python autocmd so the
-- user's autostart machinery (`vim.lsp.enable("pyright")`, lspconfig)
-- gets a chance to spawn one for the shadow buffer.
local function ensure_lsp_attached(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local attached_any = false
  local existing = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    existing[c.id] = true
  end

  for _, client in ipairs(vim.lsp.get_clients()) do
    if not existing[client.id] then
      local fts = (client.config and client.config.filetypes) or {}
      for _, ft in ipairs(fts) do
        if ft == "python" then
          pcall(vim.lsp.buf_attach_client, bufnr, client.id)
          attached_any = true
          break
        end
      end
    else
      attached_any = true
    end
  end

  if not attached_any then
    pcall(vim.api.nvim_exec_autocmds, "FileType", {
      buffer = bufnr, modeline = false, pattern = "python",
    })
  end
end

-- Compute the path to use as the shadow buffer's name. The path matters
-- because:
--   1. Many LSPs (notably pyright) reject custom URI schemes — only file://.
--   2. Pyright's analysis is workspace-relative: imports, pythonpath,
--      pyrightconfig.json, the active virtualenv. If the shadow sits in
--      stdpath("cache") it lands OUTSIDE the user's project, so pyright
--      falls back to bundled stubs and gives thin hover / no completion
--      content for third-party packages.
--
-- So we name the shadow as a sibling of the real notebook with a hidden
-- (leading-dot) basename, e.g. `/foo/bar.py` → `/foo/.bar.marimo-shadow.py`.
-- Pyright walks up from that URI to find the workspace markers (.git,
-- pyproject.toml, …) the same way it would from the real file, and
-- inherits the same env. Nothing is written to disk: the buffer is
-- `buftype=nofile`, so the shadow lives entirely in memory and the
-- "parent directory" is just whatever already exists on disk.
local function shadow_filepath(filepath)
  local dir = vim.fn.fnamemodify(filepath, ":h")
  local basename = vim.fn.fnamemodify(filepath, ":t")
  -- Strip the trailing .py if present so we don't end up with `.bar.py.marimo-shadow.py`.
  local stem = basename:gsub("%.py$", "")
  return dir .. "/." .. stem .. ".marimo-shadow.py"
end

-- Find or create the shadow buffer for this notebook. The buffer is
-- unlisted, has filetype=python (so the user's pyright/pylsp/etc.
-- autostarts), and is given a real path under stdpath("cache") so
-- LSPs that gate on URI scheme accept it.
local function ensure_shadow_buf(nb)
  local entry = M._shadows[nb.filepath]
  if entry and vim.api.nvim_buf_is_valid(entry.bufnr) then
    ensure_lsp_attached(entry.bufnr)
    return entry
  end

  -- Important: `nvim_create_buf(_, true)` creates a scratch buffer,
  -- which lspconfig's autostart filters out (it skips buftype=nofile).
  -- We use (false, false) and configure the buftype ourselves; pairing
  -- "nofile" with a manual buf_attach_client gives the right shape
  -- (no disk I/O, no swapfile, LSP still attached).
  local buf = vim.api.nvim_create_buf(false, false)
  pcall(vim.api.nvim_buf_set_name, buf, shadow_filepath(nb.filepath))
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("buflisted", false, { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "python", { buf = buf })

  entry = {
    bufnr = buf,
    cell_offsets = {},
    last_shadow_text = nil,
  }
  M._shadows[nb.filepath] = entry

  ensure_lsp_attached(buf)
  return entry
end

-- Refresh the shadow buffer from the current notebook cells. No-op if the
-- text hasn't changed. The plan calls for a 500ms debounce on edits; we
-- skip the debounce here and call this synchronously from the LSP entry
-- points instead — easier and avoids races where the user invokes K
-- while the debounce is still pending.
function M.refresh_shadow(nb)
  if not nb or not nb.cells then return nil end

  -- Make sure offsets reflect the current buffer state before we read
  -- cell.code (which may be stale until the on_bytes debounce fires).
  if nb._flush_pending then nb._flush_pending() end
  if nb.bufnr and vim.api.nvim_buf_is_valid(nb.bufnr) then
    require("neo-marimo.buffer").sync_cells_from_buffer(nb)
  end

  local entry = ensure_shadow_buf(nb)
  local text, offsets = build_shadow_text(nb)

  if text == entry.last_shadow_text then
    return entry
  end

  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_set_option_value("modifiable", true, { buf = entry.bufnr })

  -- nvim_buf_set_lines is blocked under textlock (E565), which fires when
  -- we're invoked from inside an omnifunc / completion context. The
  -- common case there is: user just typed `np.` and immediately hit
  -- <C-x><C-o>, so the on_bytes debounce hasn't fired yet — without a
  -- workaround, pyright would still see `np` (no dot) and answer "no
  -- completions" while our offsets point past EOL.
  --
  -- Workaround: still update cell_offsets to match the intended content,
  -- and tell the LSP about it via a synthetic textDocument/didChange.
  -- This keeps in-flight requests consistent with the live notebook
  -- without touching the buffer. We deliberately leave last_shadow_text
  -- unset so the next non-textlock refresh actually writes the buffer
  -- (which lets nvim's internal change tracker take over again).
  local ok = pcall(vim.api.nvim_buf_set_lines, entry.bufnr, 0, -1, false, lines)
  if not ok then
    entry.cell_offsets = offsets
    M._push_didchange(entry.bufnr, text)
    return entry
  end

  entry.cell_offsets = offsets
  entry.last_shadow_text = text
  return entry
end

-- Synthesize a `textDocument/didChange` notification for every client
-- attached to `bufnr` with the given full-document text. Used when we
-- couldn't write the shadow buffer (textlock) but still want the LSP to
-- analyze the live content. Version is monotonic in milliseconds so it
-- won't collide with whatever nvim's internal change tracker is using —
-- if anything, our number is far ahead, and the next legitimate change
-- nvim flushes will just re-set the same content.
function M._push_didchange(bufnr, text)
  local uri = vim.uri_from_bufnr(bufnr)
  local version = math.floor(vim.uv.hrtime() / 1e6)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    pcall(function()
      client:notify("textDocument/didChange", {
        textDocument = { uri = uri, version = version },
        contentChanges = { { text = text } },
      })
    end)
  end
end

-- Convert a notebook (row, col) to the corresponding shadow (row, col).
-- Returns nil if `row` falls outside any cell (e.g., the cursor sits on
-- a virtual border line — that's expected; LSP requests should no-op).
-- Exposed on M for the blink.cmp source to consume; the local alias
-- below keeps the existing in-module call sites concise.
function M.notebook_to_shadow_pos(nb, entry, row, col)
  if not entry.cell_offsets or #entry.cell_offsets == 0 then
    return nil
  end
  for i, cell in ipairs(nb.cells) do
    if row >= cell.start_row and row <= cell.end_row then
      local off = entry.cell_offsets[i]
      if not off then return nil end
      local shadow_row = off.shadow_start_row + (row - cell.start_row)
      local shadow_col = col + off.col_shift
      return shadow_row, shadow_col, i
    end
  end
  return nil
end
local notebook_to_shadow_pos = M.notebook_to_shadow_pos

-- Inverse mapping: shadow (row, col) → notebook (row, col). Used to
-- translate goto-definition results so the jump lands inside the
-- notebook buffer rather than the shadow.
local function shadow_to_notebook_pos(nb, entry, shadow_row, shadow_col)
  if not entry.cell_offsets then return nil end
  for i, cell in ipairs(nb.cells) do
    local off = entry.cell_offsets[i]
    if not off then goto continue end
    local cell_lines = cell.end_row - cell.start_row + 1
    if shadow_row >= off.shadow_start_row
        and shadow_row < off.shadow_start_row + cell_lines then
      local row = cell.start_row + (shadow_row - off.shadow_start_row)
      local col = shadow_col - off.col_shift
      if col < 0 then col = 0 end
      return row, col
    end
    ::continue::
  end
  return nil
end

-- Send an LSP request from the notebook buffer by routing it through the
-- shadow buffer. `method` is a textDocument/* request name. `extra_params`
-- is merged into the LSP params before sending. `handler` is the result
-- callback `(result, ctx) -> any`. If no LSP client is attached to the
-- shadow buffer, falls back to `fallback_msg`.
local function request_via_shadow(nb, method, extra_params, handler, fallback_msg)
  local entry = M.refresh_shadow(nb)
  if not entry then
    vim.notify("[neo-marimo] " .. (fallback_msg or "shadow buffer unavailable"),
      vim.log.levels.WARN)
    return
  end

  -- Make sure pyright/etc. has had a chance to attach to the shadow. The
  -- user's lspconfig usually wires LSP attach via FileType autocmds; the
  -- shadow's filetype is set at creation time, so the autocmds will have
  -- fired. Verify and complain if nothing is attached.
  local clients = vim.lsp.get_clients({ bufnr = entry.bufnr })
  if #clients == 0 then
    vim.notify(
      "[neo-marimo] No LSP attached to shadow buffer. Install a Python LSP " ..
      "(e.g. pyright, basedpyright, pylsp) and ensure it autostarts on " ..
      "filetype=python.",
      vim.log.levels.WARN
    )
    return
  end

  -- Translate the current cursor position.
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]

  -- Refuse to send requests when the cursor sits on a virtual border line
  -- (between cells). Verification step 5 of the plan calls for hover to
  -- "return nothing" inside a `mo.md("…")` body; we honor that by checking
  -- whether the cursor is inside a string node — see is_in_markdown_string.
  if M.is_in_markdown_string(nb.bufnr or 0, row, col) then
    return
  end

  local shadow_row, shadow_col = notebook_to_shadow_pos(nb, entry, row, col)
  if not shadow_row then
    return
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(entry.bufnr),
    position = { line = shadow_row, character = shadow_col },
  }
  for k, v in pairs(extra_params or {}) do
    params[k] = v
  end

  vim.lsp.buf_request(entry.bufnr, method, params, function(err, result, ctx, config)
    handler(err, result, ctx, config, { nb = nb, entry = entry })
  end)
end

-- Public: hover the symbol under the cursor.
--
-- We render the floating preview directly instead of routing through
-- `vim.lsp.handlers["textDocument/hover"]`. In recent nvim versions the
-- standard hover path delegates to `vim.lsp.buf.hover()`, which checks
-- the *current* buffer's clients and warns "method textDocument/hover
-- is not supported by any server activated for this buffer" — but the
-- current buffer is the notebook view, and no LSP is (or should be)
-- attached there. The LSP work happens on the shadow buffer.
function M.hover()
  local nb = require("neo-marimo").current_notebook()
  if not nb then return end

  request_via_shadow(nb, "textDocument/hover", nil, function(err, result)
    if err or not result or not result.contents then return end
    local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
    if not lines or #lines == 0 then return end
    lines = trim_empty_lines(lines)
    if #lines == 0 then return end
    vim.lsp.util.open_floating_preview(lines, "markdown", {
      border = "rounded",
      focus = false,
      focusable = true,
      -- Pyright's hover for an overloaded function (e.g. numpy.array)
      -- can run 40+ lines of signature alternatives. The default
      -- max_height (~0.4 * o.lines) clips most of those, making the
      -- hover look thin compared to other editors that wrap-scroll the
      -- whole response. Give it most of the screen instead — users can
      -- close the float with <C-w>w or by moving the cursor.
      max_width  = math.min(100, math.floor(vim.o.columns * 0.7)),
      max_height = math.max(10, math.floor(vim.o.lines * 0.7)),
    })
  end, "Hover unavailable: no notebook attached")
end

-- Public: signature help (typically bound to <C-k> in insert mode).
-- Renders the float directly for the same reason as M.hover — the
-- standard handler in newer nvim versions consults the current buffer
-- for capability, which is the notebook view (no LSP attached).
function M.signature()
  local nb = require("neo-marimo").current_notebook()
  if not nb then return end

  request_via_shadow(nb, "textDocument/signatureHelp", nil, function(err, result)
    if err or not result or not result.signatures or #result.signatures == 0 then
      return
    end
    local sig = result.signatures[result.activeSignature and (result.activeSignature + 1) or 1]
        or result.signatures[1]
    if not sig then return end
    local lines = { sig.label or "" }
    if sig.documentation then
      local doc = type(sig.documentation) == "table"
          and sig.documentation.value or sig.documentation
      if doc and doc ~= "" then
        table.insert(lines, "")
        for ln in (doc .. "\n"):gmatch("([^\n]*)\n") do
          table.insert(lines, ln)
        end
      end
    end
    vim.lsp.util.open_floating_preview(lines, "markdown", {
      border = "rounded", focus = false,
      max_width = math.min(80, math.floor(vim.o.columns * 0.6)),
    })
  end, "Signature help unavailable")
end

-- Public: completion at the cursor. Designed as a vim 'completefunc'
-- driver: returns -3 (cancel) when not in a usable context, otherwise
-- triggers an async LSP completion and returns the offset/items.
-- For most users this will be invoked via omnifunc (<C-x><C-o>).
function M.completefunc(findstart, base)
  -- vim's two-call protocol:
  --   first call (findstart == 1): return the byte offset where the match starts
  --   second call: return matches starting from that offset
  local nb = require("neo-marimo").current_notebook()
  if not nb then return findstart == 1 and -3 or {} end

  if findstart == 1 then
    -- Determine where the current word starts. Same heuristic as omnifunc:
    -- scan back from the cursor over [A-Za-z0-9_.].
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], false)[1] or ""
    local col = cursor[2]
    local start = col
    while start > 0 do
      local ch = line:sub(start, start)
      if ch:match("[%w_%.]") then
        start = start - 1
      else
        break
      end
    end
    return start
  end

  -- second call: kick off the request synchronously-with-wait
  local entry = M.refresh_shadow(nb)
  if not entry then return {} end
  local clients = vim.lsp.get_clients({ bufnr = entry.bufnr })
  if #clients == 0 then return {} end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  if M.is_in_markdown_string(nb.bufnr or 0, row, col) then
    return {}
  end
  local shadow_row, shadow_col = notebook_to_shadow_pos(nb, entry, row, col)
  if not shadow_row then return {} end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(entry.bufnr),
    position = { line = shadow_row, character = shadow_col },
  }

  local results = {}
  local done = false
  vim.lsp.buf_request(entry.bufnr, "textDocument/completion", params, function(_, result)
    local items = (result and result.items) or result or {}
    if type(items) == "table" then
      for _, item in ipairs(items) do
        local label = item.label or item.insertText or ""
        local kind = item.kind and vim.lsp.protocol.CompletionItemKind[item.kind] or ""
        local detail = item.detail or ""
        table.insert(results, {
          word = (item.insertText or item.label or ""):gsub("[%(%)].*$", ""),
          abbr = label,
          menu = (kind ~= "" and ("[" .. kind .. "] ") or "") .. detail,
          info = (item.documentation and item.documentation.value) or item.documentation or "",
          icase = 1,
        })
      end
    end
    done = true
  end)

  -- Bounded wait — completion needs to feel snappy, and vim's omnifunc
  -- is synchronous. 250ms is enough for a warm pyright; if the user is
  -- on cold start, the second invocation will hit cache.
  vim.wait(250, function() return done end, 10)
  return results
end

-- Public: goto definition. Translates the LSP location back into notebook
-- coordinates so the jump lands in the user's view rather than the shadow.
function M.goto_definition()
  local nb = require("neo-marimo").current_notebook()
  if not nb then return end

  request_via_shadow(nb, "textDocument/definition", nil, function(err, result, _, _, route)
    if err or not result then return end
    if vim.tbl_isempty(result) then return end
    local entry = route.entry

    -- LSP can return a single Location or a list. Pick the first.
    local target = result[1] or result
    local target_uri = target.uri or target.targetUri
    local target_range = target.range or target.targetSelectionRange or target.targetRange
    if not target_range then return end

    local shadow_uri = vim.uri_from_bufnr(entry.bufnr)
    if target_uri == shadow_uri then
      -- Definition is inside our shadow → translate back to the notebook.
      local sr, sc = target_range.start.line, target_range.start.character
      local nb_row, nb_col = shadow_to_notebook_pos(nb, entry, sr, sc)
      if nb_row and nb.bufnr and vim.api.nvim_buf_is_valid(nb.bufnr) then
        vim.api.nvim_win_set_cursor(0, { nb_row + 1, math.max(0, nb_col) })
      end
      return
    end

    -- External file (stdlib, third-party lib). Fall back to the standard
    -- LSP handler so the user's preferred jumplist / file-open behavior
    -- is preserved.
    local handler = vim.lsp.handlers["textDocument/definition"]
    if handler then
      handler(err, result, {
        client_id = (route.entry and 0) or 0,
        method = "textDocument/definition",
        bufnr = nb.bufnr or 0,
      }, {})
    end
  end, "Goto definition unavailable")
end

-- Check whether the cursor sits inside a `mo.md("…")` triple-quoted body.
-- The plan calls for hover inside markdown injections to return nothing
-- rather than erroring.
--
-- We pick the enclosing cell, and if it's a markdown cell we suppress
-- LSP requests *except* on the line that contains the `mo.md(` opener
-- (so hover on the `mo`/`mo.md` tokens themselves still works). This
-- is coarser than a real treesitter node query but it's allocation-free
-- and gets the practical cases right without depending on a parser.
function M.is_in_markdown_string(bufnr, row, _col)
  local nb = require("neo-marimo").current_notebook()
  if not nb then return false end
  for _, cell in ipairs(nb.cells) do
    if row >= cell.start_row and row <= cell.end_row then
      if cell.type ~= "markdown" then return false end
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      -- The opener-row (containing `mo.md(`) is real Python; everything
      -- else inside the cell is markdown body — including a possible
      -- closing `""")` line on its own.
      if line:match("mo%.md%s*%(") then return false end
      return true
    end
  end
  return false
end

-- Clean up the shadow buffer for a notebook. Called when the notebook
-- buffer is wiped so we don't leak hidden buffers across sessions.
function M.cleanup(filepath)
  local entry = M._shadows[filepath]
  if entry and vim.api.nvim_buf_is_valid(entry.bufnr) then
    pcall(vim.api.nvim_buf_delete, entry.bufnr, { force = true })
  end
  M._shadows[filepath] = nil
end

-- Global trampolines so `omnifunc` and `tagfunc` (which only accept a vim
-- function name, not arbitrary expressions) can reach into this module.
-- Set once at module load.
_G.neo_marimo_omnifunc = function(findstart, base)
  return M.completefunc(findstart == 1 and 1 or 0, base or "")
end

return M

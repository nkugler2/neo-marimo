-- Phase 8.5 — DataFrame side-panel.
--
-- The inline `application/vnd.dataresource+json` renderer in output.lua tops
-- out at 5 rows so it fits as a virt_line. For the full data, the user
-- presses <leader>mD (or runs :MarimoDataFramePanel) and we open a vertical
-- split on the right with the entire payload as a navigable buffer.
--
-- Features in this pass:
--   * Full row count, no cap
--   * `s` on a column header sorts by that column
--   * `?` shows the keymap help line
--   * `q` / <Esc> closes the panel
--   * column widths sized to content (capped at 30 chars per column)

local notebook = require("neo-marimo.notebook")

local M = {}

-- Track the open panel so a second <leader>mD focuses the existing one
-- instead of opening a duplicate vsplit. Keyed by source notebook bufnr.
M._panels = {}

-- ── data extraction ──────────────────────────────────────────────────────

-- Pull a DataFrame-shaped output off a cell. We accept any cell whose
-- `output.mimetype == "application/vnd.dataresource+json"`. Returns
-- `{ rows = {...}, cols = {...} }` or nil if the cell has no compatible
-- output.
local function extract_dataresource(cell)
  if not cell or not cell.output then return nil end
  if cell.output.mimetype ~= "application/vnd.dataresource+json" then
    return nil
  end
  local data = cell.output.data
  if type(data) ~= "table" or type(data.data) ~= "table" then return nil end
  local rows = data.data
  if #rows == 0 then return { rows = {}, cols = {} } end

  -- Column order: use schema.fields if marimo sent one (preserves the
  -- pandas column order), otherwise fall back to sorted keys.
  local cols = {}
  if type(data.schema) == "table" and type(data.schema.fields) == "table" then
    for _, f in ipairs(data.schema.fields) do
      if type(f) == "table" and f.name then
        table.insert(cols, f.name)
      end
    end
  end
  if #cols == 0 then
    for k, _ in pairs(rows[1]) do table.insert(cols, k) end
    table.sort(cols)
  end
  return { rows = rows, cols = cols }
end

-- ── rendering ────────────────────────────────────────────────────────────

local MAX_COL_WIDTH = 30

-- Compute padded widths for every column. Widths cap at MAX_COL_WIDTH so a
-- single fat column doesn't blow the panel out beyond the user's window.
-- The sort-arrow suffix is included in the header sizing so the header and
-- separator lines stay vertically aligned even after the user sorts.
local function compute_widths(df, sort_col)
  local widths = {}
  for _, c in ipairs(df.cols) do
    local hdr_w = #c
    if c == sort_col then hdr_w = hdr_w + 2 end  -- " ▲" or " ▼"
    widths[c] = math.max(hdr_w, 4)
  end
  for _, row in ipairs(df.rows) do
    for _, c in ipairs(df.cols) do
      local v = tostring(row[c] or "")
      if #v > widths[c] then widths[c] = math.min(#v, MAX_COL_WIDTH) end
    end
  end
  return widths
end

-- Pad/truncate `s` to exactly `cells` display cells. `widths[c]` is sized in
-- bytes from compute_widths (which assumes ASCII content); the sort arrow is
-- 3 bytes / 1 cell, so naïve `string.format("%-Ns", …)` overruns the budget
-- and breaks vertical alignment.
local function pad_display(s, cells)
  local w = vim.fn.strdisplaywidth(s)
  if w == cells then return s end
  if w < cells then return s .. string.rep(" ", cells - w) end
  -- truncate in codepoint-safe steps until we fit
  local total = vim.fn.strchars(s)
  for n = total, 0, -1 do
    local cand = vim.fn.strcharpart(s, 0, n)
    if vim.fn.strdisplaywidth(cand) <= cells then
      return cand .. string.rep(" ", cells - vim.fn.strdisplaywidth(cand))
    end
  end
  return string.rep(" ", cells)
end

local function build_lines(df, sort_col, sort_desc)
  local widths = compute_widths(df, sort_col)
  local lines = {}

  -- Header row — append sort arrow inline so column width math stays
  -- consistent with the separator and data rows below.
  local header = "│"
  for _, c in ipairs(df.cols) do
    local label = c
    if c == sort_col then label = label .. (sort_desc and " ▼" or " ▲") end
    header = header .. " " .. pad_display(label, widths[c]) .. " │"
  end
  table.insert(lines, header)

  -- Separator
  local sep = "├"
  for j, c in ipairs(df.cols) do
    sep = sep .. string.rep("─", widths[c] + 2) .. (j < #df.cols and "┼" or "┤")
  end
  table.insert(lines, sep)

  for _, row in ipairs(df.rows) do
    local line = "│"
    for _, c in ipairs(df.cols) do
      local v = tostring(row[c] or "")
      v = v:sub(1, widths[c])
      line = line .. string.format(" %-" .. widths[c] .. "s │", v)
    end
    table.insert(lines, line)
  end

  table.insert(lines, "")
  table.insert(lines, string.format("%d rows · %d columns", #df.rows, #df.cols))
  table.insert(lines, "press `s` over a header to sort · `?` help · `q`/<Esc> close")

  return lines, widths
end

-- Find which column the cursor sits on (1-indexed into df.cols). Returns nil
-- if the cursor isn't over a data column (e.g. on the row-number area or a
-- separator line).
local function column_at_cursor(panel)
  local pos = vim.api.nvim_win_get_cursor(panel.win)
  local col = pos[2]  -- 0-indexed byte column

  -- Skip the leading "│ " prefix
  local x = 2
  for j, c in ipairs(panel.df.cols) do
    local w = panel.widths[c]
    -- Each column occupies width + 3 bytes: " %-w s │"
    if col >= x and col < x + w + 1 then
      return j, c
    end
    x = x + w + 3
  end
  return nil
end

-- Stable sort by column, asc on first hit, toggle to desc on a second hit.
local function sort_by(panel, col_name)
  if panel.sort_col == col_name then
    panel.sort_desc = not panel.sort_desc
  else
    panel.sort_col = col_name
    panel.sort_desc = false
  end

  local desc = panel.sort_desc
  table.sort(panel.df.rows, function(a, b)
    local av = a[col_name]
    local bv = b[col_name]
    local an = tonumber(av)
    local bn = tonumber(bv)
    if an and bn then
      if desc then return an > bn end
      return an < bn
    end
    av = tostring(av or "")
    bv = tostring(bv or "")
    if desc then return av > bv end
    return av < bv
  end)

  M._redraw(panel)
end

function M._redraw(panel)
  if not vim.api.nvim_buf_is_valid(panel.buf) then return end
  local lines, widths = build_lines(panel.df, panel.sort_col, panel.sort_desc)
  panel.widths = widths

  vim.api.nvim_set_option_value("modifiable", true, { buf = panel.buf })
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = panel.buf })
end

-- ── open / close ─────────────────────────────────────────────────────────

function M.open_for_cell(nb, cell)
  local df = extract_dataresource(cell)
  if not df or not df.cols or #df.cols == 0 then
    vim.notify("[neo-marimo] No DataFrame output on the cell under the cursor.",
      vim.log.levels.WARN)
    return
  end

  -- If a panel for this notebook already exists and is alive, focus and
  -- refresh it instead of opening another vsplit.
  local existing = M._panels[nb.bufnr]
  if existing
      and vim.api.nvim_win_is_valid(existing.win)
      and vim.api.nvim_buf_is_valid(existing.buf) then
    existing.df = df
    existing.sort_col = nil
    existing.sort_desc = false
    M._redraw(existing)
    vim.api.nvim_set_current_win(existing.win)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "marimo-dataframe", { buf = buf })
  vim.api.nvim_buf_set_name(buf, "marimo://dataframe/" ..
    (cell.name and cell.name ~= "_" and cell.name or "cell" .. tostring(cell.index)))

  -- Open as a vertical split on the right side. The user can resize with
  -- the usual `<C-w>>`/`<C-w><` once it's open.
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, math.max(60, math.floor(vim.o.columns * 0.45)))

  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })

  local panel = {
    buf = buf, win = win, nb = nb, cell = cell, df = df, widths = {},
    sort_col = nil, sort_desc = false,
  }
  M._panels[nb.bufnr] = panel
  M._redraw(panel)

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    M._panels[nb.bufnr] = nil
  end

  local function bind(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, {
      buffer = buf, silent = true, noremap = true, desc = desc,
    })
  end

  bind("q",     close, "Close DataFrame panel")
  bind("<Esc>", close, "Close DataFrame panel")
  bind("s", function()
    local _, name = column_at_cursor(panel)
    if name then sort_by(panel, name) end
  end, "Sort by the column under the cursor")
  bind("?", function()
    vim.notify(table.concat({
      "Marimo DataFrame panel",
      "  s       sort by column under cursor (toggle asc/desc)",
      "  q / <Esc> close",
      "  ?       this help",
    }, "\n"), vim.log.levels.INFO)
  end, "Show DataFrame panel help")

  -- Clean up the registry slot if the panel buffer is wiped from under us.
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function() M._panels[nb.bufnr] = nil end,
  })

  -- Park cursor on the header row so the first `s` press lands on a column.
  vim.api.nvim_win_set_cursor(win, { 1, 2 })
end

-- Convenience entry that finds the cell at the cursor and opens the panel.
function M.open_at_cursor()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  if nb._flush_pending then nb._flush_pending() end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell = notebook.get_cell_at_row(nb, row)
  if not cell then
    vim.notify("[neo-marimo] Cursor is not over a cell.", vim.log.levels.WARN)
    return
  end
  M.open_for_cell(nb, cell)
end

return M

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
local html_mod = require("neo-marimo.html")

local M = {}

-- Track the open panel so a second <leader>mD focuses the existing one
-- instead of opening a duplicate vsplit. Keyed by source notebook bufnr.
M._panels = {}

-- ── data extraction ──────────────────────────────────────────────────────
--
-- DataFrames reach us in four different shapes depending on what marimo's
-- formatters did to them. Each parser below handles one shape and returns
-- the same {cols, rows} struct so the rest of the module (panel + inline
-- renderer) doesn't care where the data came from:
--
--   shape 1  application/vnd.dataresource+json
--            { schema = {fields = [...]}, data = [{col:val, ...}] }
--            Explicit, structured. Used when a formatter is registered.
--
--   shape 2  text/html with <marimo-table data-data="…JSON…">
--            mo.ui.table auto-wraps pandas/polars DataFrames; data is
--            embedded as JSON in attributes.
--
--   shape 3  text/html with plain <table><thead>…</thead><tbody>…</tbody>
--            Pandas' df.to_html() output. Includes an unwanted leading
--            row-index column we strip.
--
--   shape 4  application/vnd.marimo+mime envelope wrapping any of 1-3.

-- Entity decoding is html.lua's job (single copy, named + numeric refs);
-- this just drops the tags and trims.
local function strip_tags(s)
  if type(s) ~= "string" then return tostring(s or "") end
  return (html_mod.decode_entities(s:gsub("<[^>]+>", "")):match("^%s*(.-)%s*$"))
end

-- Read an attribute value out of an opener tag (e.g. `<marimo-table
-- data-data="…">`). Handles double- and single-quoted forms.
local function read_attr(tag_open, name)
  local pat_name = name:gsub("%-", "%%-")
  return tag_open:match(pat_name .. '%s*=%s*"([^"]*)"')
      or tag_open:match(pat_name .. "%s*=%s*'([^']*)'")
end

-- Decode an attribute value that holds JSON. Marimo HTML-entity-encodes
-- the value on the wire (including &#92; for escaping backslashes inside
-- nested JSON strings) and sometimes double-encodes the JSON itself —
-- both layers are handled by html.lua's shared decoders.
local function decode_json_attr(s)
  if type(s) ~= "string" or s == "" then return nil end
  return html_mod.json_attr(html_mod.decode_entities(s))
end

-- Shape 1: application/vnd.dataresource+json.
local function parse_dataresource(data)
  if type(data) ~= "table" or type(data.data) ~= "table" then return nil end
  local rows = data.data

  local cols = {}
  if type(data.schema) == "table" and type(data.schema.fields) == "table" then
    for _, f in ipairs(data.schema.fields) do
      if type(f) == "table" and f.name then
        table.insert(cols, f.name)
      end
    end
  end
  if #cols == 0 and rows[1] then
    for k, _ in pairs(rows[1]) do table.insert(cols, k) end
    table.sort(cols)
  end
  return { rows = rows, cols = cols }
end

-- Forward declaration: parse_marimo_table falls back to parse_html_table
-- for HTML embedded inside `<marimo-table>...</marimo-table>` bodies, but
-- the html-table parser appears later in the file (depends on strip_tags
-- and lives next to its own helpers). Without this forward `local`, the
-- reference inside parse_marimo_table would resolve to a nil global.
local parse_html_table

-- Try to coerce a decoded JSON value into a row list. Marimo serializes the
-- table data into several different shapes depending on which attribute it
-- lands on and which version is running:
--
--   * `[{x:1, y:"a"}, …]`               — direct list of record rows
--   * `[[1, "a"], …]`                    — direct list of positional arrays
--   * `{data: [...rows], showColumnSummaries: ...}` — wrapper record
--   * `{rows: [...], …}`, `{value: [...]}`, `{tableData: [...]}` — other wrappers
--
-- Returns the row list, or nil if the value doesn't look like rows at all.
local function rows_from_value(decoded)
  if type(decoded) ~= "table" then return nil end
  if decoded[1] ~= nil then return decoded end
  for _, key in ipairs({ "data", "rows", "value", "tableData", "table_data" }) do
    local nested = decoded[key]
    if type(nested) == "table" and nested[1] ~= nil then
      return nested
    end
  end
  return nil
end

-- Shape 2: `<marimo-table>` custom element. The actual attribute names and
-- value shapes shift between marimo versions, so we cast a wide net rather
-- than locking onto one transport.
local function parse_marimo_table(html)
  local tag_open = html:match("<marimo%-table[^>]*>")
  if not tag_open then return nil end

  -- 1. Try every attribute we've ever seen carry row data.
  local rows
  for _, attr in ipairs({
    "data-data", "data-rows", "data-table-data",
    "data-initial-value", "data-value",
  }) do
    local raw = read_attr(tag_open, attr)
    if raw then
      rows = rows_from_value(decode_json_attr(raw))
      if rows then break end
    end
  end

  -- 2. Fall back to the element body — marimo sometimes embeds the data as
  -- text content rather than as an attribute.
  if not rows then
    local body = html:match("<marimo%-table[^>]*>(.-)</marimo%-table>")
    if body and body ~= "" then
      local trimmed = body:match("^%s*(.-)%s*$") or ""
      if trimmed ~= "" then
        rows = rows_from_value(decode_json_attr(trimmed))
        -- 3. And as a last resort, a nested <table> inside the custom element.
        if not rows then
          local nested_df = parse_html_table(trimmed)
          if nested_df then return nested_df end
        end
      end
    end
  end

  -- 4. Column descriptors. data-fields is typical; data-field-types and
  -- data-columns appear in some versions.
  local cols = {}
  for _, attr in ipairs({ "data-fields", "data-field-types", "data-columns" }) do
    local fields = decode_json_attr(read_attr(tag_open, attr))
    if type(fields) == "table" then
      for _, f in ipairs(fields) do
        if type(f) == "table" then
          table.insert(cols, f.name or f[1] or "?")
        elseif type(f) == "string" then
          table.insert(cols, f)
        end
      end
      if #cols > 0 then break end
    end
  end

  -- 5. Last-resort columns: derive from the first row's keys (record shape only).
  if rows and #cols == 0 and type(rows[1]) == "table" then
    for k, _ in pairs(rows[1]) do
      if type(k) == "string" then table.insert(cols, k) end
    end
    table.sort(cols)
  end

  -- 6. Rows-as-positional-arrays → convert to records keyed by column name
  --    so render_inline / panel can index by column. Detected by: first
  --    row is a table, has numeric index [1] but no key matching cols[1].
  if rows and #cols > 0 and type(rows[1]) == "table"
      and rows[1][cols[1]] == nil and rows[1][1] ~= nil then
    local records = {}
    for _, row in ipairs(rows) do
      local rec = {}
      for i, c in ipairs(cols) do rec[c] = row[i] end
      table.insert(records, rec)
    end
    rows = records
  end

  rows = rows or {}
  if #cols == 0 then return nil end
  return { cols = cols, rows = rows }
end

-- Shape 3: plain HTML <table>. Pandas' df.to_html() format.
parse_html_table = function(html)
  local table_html = html:match("<table[^>]*>(.-)</table>")
  if not table_html then return nil end

  -- Header cells: prefer <thead>'s <th>s if present.
  local cols = {}
  local thead = table_html:match("<thead[^>]*>(.-)</thead>") or table_html
  for th in thead:gmatch("<th[^>]*>(.-)</th>") do
    table.insert(cols, strip_tags(th))
  end
  -- Pandas prefixes a blank <th></th> for the row index column.
  if #cols > 1 and cols[1] == "" then table.remove(cols, 1) end
  if #cols == 0 then return nil end

  -- Body rows. If no <tbody>, treat everything after the first </tr> (the
  -- header row) as the body.
  local tbody = table_html:match("<tbody[^>]*>(.-)</tbody>")
  if not tbody then
    local after_hdr = table_html:find("</tr>", 1, true)
    tbody = after_hdr and table_html:sub(after_hdr + 5) or table_html
  end

  local rows = {}
  for tr in tbody:gmatch("<tr[^>]*>(.-)</tr>") do
    local cells = {}
    for cell in tr:gmatch("<t[hd][^>]*>(.-)</t[hd]>") do
      table.insert(cells, strip_tags(cell))
    end
    -- Pandas prefixes each row with a <th>N</th> index. If we got one
    -- more cell than columns, the first one is the index — drop it.
    if #cells == #cols + 1 then table.remove(cells, 1) end
    if #cells == #cols then
      local row = {}
      for i, c in ipairs(cols) do row[c] = cells[i] end
      table.insert(rows, row)
    end
  end

  if #rows == 0 then return nil end
  return { cols = cols, rows = rows }
end

-- Decide which parser applies to a text/html payload.
local function extract_from_html(html)
  if type(html) ~= "string" then return nil end
  if html:find("<marimo%-table", 1) then
    local df = parse_marimo_table(html)
    if df and (#df.cols > 0 or #df.rows > 0) then return df end
  end
  if html:find("<table", 1) then
    return parse_html_table(html)
  end
  return nil
end

-- Top-level extractor. Tries each known shape; returns the first match.
local function extract_from_output(output)
  if not output then return nil end
  local mime = output.mimetype
  local data = output.data

  if mime == "application/vnd.dataresource+json" then
    return parse_dataresource(data)
  end
  if mime == "text/html" and type(data) == "string" then
    return extract_from_html(data)
  end
  if mime == "application/vnd.marimo+mime"
      and type(data) == "table" and data.mimetype then
    return extract_from_output({ mimetype = data.mimetype, data = data.data })
  end
  return nil
end

-- Expose extractors so output.lua can call them from render_html.
M.extract_from_html = extract_from_html
M.extract_from_output = extract_from_output
M.parse_dataresource = parse_dataresource

-- ── inline preview (used by output.lua for cell virt_lines) ──────────────
--
-- The shape mirrors what the panel uses: { cols = {...}, rows = {...} }.
-- Row count is capped (5 by default) and we point the user at <leader>mD
-- for the full view.

local INLINE_MAX_ROWS = 5
local INLINE_COL_CAP = 20

-- Pad/truncate `s` to exactly `cells` display cells. Widths everywhere in
-- this module are display cells (not bytes) so non-ASCII headers/values —
-- CJK, emoji, accented text — keep vertical alignment; naïve
-- `string.format("%-Ns", …)` counts bytes and overruns the budget.
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

function M.render_inline(df, opts)
  opts = opts or {}
  local max_rows = opts.max_rows or INLINE_MAX_ROWS
  if not df or not df.cols or #df.cols == 0 then
    return { { { "  [table]", "MarimoOutputText" } } }
  end
  if #df.rows == 0 then
    return { { { "  [empty table — " .. #df.cols ..
      " column" .. (#df.cols == 1 and "" or "s") .. "]", "MarimoOutputText" } } }
  end

  local widths = {}
  for _, c in ipairs(df.cols) do
    widths[c] = math.max(vim.fn.strdisplaywidth(tostring(c)), 4)
  end
  for i = 1, math.min(max_rows, #df.rows) do
    for _, c in ipairs(df.cols) do
      local w = vim.fn.strdisplaywidth(tostring(df.rows[i][c] or ""))
      if w > widths[c] then widths[c] = math.min(w, INLINE_COL_CAP) end
    end
  end

  local lines = {}
  -- Header row
  local header = "  │"
  for _, c in ipairs(df.cols) do
    header = header .. " " .. pad_display(tostring(c), widths[c]) .. " │"
  end
  table.insert(lines, { { header, "MarimoOutputText" } })

  -- Separator
  local sep = "  ├"
  for _, c in ipairs(df.cols) do
    sep = sep .. string.rep("─", widths[c] + 2) .. "┤"
  end
  table.insert(lines, { { sep, "MarimoOutputText" } })

  local shown = math.min(max_rows, #df.rows)
  for i = 1, shown do
    local s = "  │"
    for _, c in ipairs(df.cols) do
      s = s .. " " .. pad_display(tostring(df.rows[i][c] or ""), widths[c]) .. " │"
    end
    table.insert(lines, { { s, "MarimoOutputText" } })
  end

  if #df.rows > shown then
    table.insert(lines, {
      { "  … " .. (#df.rows - shown) .. " more rows · ", "Comment" },
      { "<leader>mD", "MarimoMarkdownInlineCode" },
      { " for full panel", "Comment" },
    })
  end
  return lines
end

-- ── rendering ────────────────────────────────────────────────────────────

local MAX_COL_WIDTH = 30

-- Compute padded widths (display cells) for every column. Widths cap at
-- MAX_COL_WIDTH so a single fat column doesn't blow the panel out beyond
-- the user's window. The sort-arrow suffix is included in the header sizing
-- so the header and separator lines stay vertically aligned after a sort.
local function compute_widths(df, sort_col)
  local widths = {}
  for _, c in ipairs(df.cols) do
    local hdr_w = vim.fn.strdisplaywidth(c)
    if c == sort_col then hdr_w = hdr_w + 2 end  -- " ▲" or " ▼"
    widths[c] = math.max(hdr_w, 4)
  end
  for _, row in ipairs(df.rows) do
    for _, c in ipairs(df.cols) do
      local w = vim.fn.strdisplaywidth(tostring(row[c] or ""))
      if w > widths[c] then widths[c] = math.min(w, MAX_COL_WIDTH) end
    end
  end
  return widths
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
      line = line .. " " .. pad_display(tostring(row[c] or ""), widths[c]) .. " │"
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
-- separator line). Cursor position arrives as a byte column but widths are
-- display cells — convert via strdisplaywidth of the line up to the cursor,
-- otherwise multi-byte content ("│" is 3 bytes / 1 cell, CJK is 3 bytes /
-- 2 cells) shifts every boundary and `s` sorts the wrong column.
local function column_at_cursor(panel)
  local pos = vim.api.nvim_win_get_cursor(panel.win)
  local line = vim.api.nvim_buf_get_lines(panel.buf, pos[1] - 1, pos[1], false)[1] or ""
  local col = vim.fn.strdisplaywidth(line:sub(1, pos[2]))  -- 0-indexed display column

  -- Skip the leading "│ " prefix
  local x = 2
  for j, c in ipairs(panel.df.cols) do
    local w = panel.widths[c]
    -- Each column occupies width + 3 display cells: " <content> │"
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
  local df = cell and extract_from_output(cell.output)
  if not df or not df.cols or #df.cols == 0 then
    vim.notify(
      "[neo-marimo] No DataFrame output on the cell under the cursor. " ..
        "(run :MarimoInspectOutput to see what marimo sent)",
      vim.log.levels.WARN
    )
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

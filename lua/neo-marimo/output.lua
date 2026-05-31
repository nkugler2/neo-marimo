-- Cell output rendering via extmark virtual lines.
-- Handles the cell-op messages from the marimo WebSocket.

local hl = require("neo-marimo.highlights")
local notebook_mod = require("neo-marimo.notebook")

local M = {}

-- Maximum output lines to show per cell before truncating.
local MAX_LINES = 30

-- ── MIME type rendering ─────────────────────────────────────────────────────

local function render_text_plain(data)
  if type(data) ~= "string" then
    data = tostring(data)
  end
  local lines = {}
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, { { "  " .. line, "MarimoOutputText" } })
  end
  return lines
end

local function render_error(data)
  -- data is a list of Error objects: [{type, msg, frames}]
  local lines = {}
  if type(data) == "table" then
    for _, err in ipairs(data) do
      local etype = (type(err) == "table" and err.type) or "Error"
      local msg = (type(err) == "table" and err.msg) or tostring(err)
      table.insert(lines, { { "  ✖ " .. etype .. ": " .. msg, "MarimoOutputError" } })
    end
  else
    table.insert(lines, { { "  ✖ " .. tostring(data), "MarimoOutputError" } })
  end
  return lines
end

local function render_html(data)
  -- Strip HTML tags (best-effort) and show plain text
  if type(data) ~= "string" then return {} end
  local stripped = data:gsub("<[^>]+>", ""):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
  stripped = stripped:match("^%s*(.-)%s*$")  -- trim
  if stripped == "" then return {} end
  return render_text_plain(stripped)
end

local function render_dataresource(data)
  -- data is {schema: {...}, data: [{col: val, ...}]}
  if type(data) ~= "table" or not data.data then
    return { { { "  [table]", "MarimoOutputText" } } }
  end

  local rows = data.data
  if #rows == 0 then
    return { { { "  [empty table]", "MarimoOutputText" } } }
  end

  -- Collect columns from first row
  local cols = {}
  for k, _ in pairs(rows[1]) do
    table.insert(cols, k)
  end
  table.sort(cols)

  -- Build header
  local col_widths = {}
  for _, col in ipairs(cols) do
    col_widths[col] = math.max(#col, 4)
  end
  -- Measure data widths (up to 5 rows)
  for i = 1, math.min(5, #rows) do
    for _, col in ipairs(cols) do
      local val = tostring(rows[i][col] or "")
      if #val > col_widths[col] then
        col_widths[col] = math.min(#val, 20)
      end
    end
  end

  local lines = {}
  -- Header row
  local header = "  │"
  for _, col in ipairs(cols) do
    local cell_str = col:sub(1, col_widths[col])
    header = header .. string.format(" %-" .. col_widths[col] .. "s │", cell_str)
  end
  table.insert(lines, { { header, "MarimoOutputText" } })

  -- Separator
  local sep = "  ├"
  for _, col in ipairs(cols) do
    sep = sep .. string.rep("─", col_widths[col] + 2) .. "┤"
  end
  table.insert(lines, { { sep, "MarimoOutputText" } })

  -- Data rows (max 5)
  for i = 1, math.min(5, #rows) do
    local row_str = "  │"
    for _, col in ipairs(cols) do
      local val = tostring(rows[i][col] or ""):sub(1, col_widths[col])
      row_str = row_str .. string.format(" %-" .. col_widths[col] .. "s │", val)
    end
    table.insert(lines, { { row_str, "MarimoOutputText" } })
  end

  if #rows > 5 then
    table.insert(lines, { { "  … " .. (#rows - 5) .. " more rows", "MarimoOutputText" } })
  end

  return lines
end

-- Convert a CellOutput object (from the WS message) to virt_lines chunks.
local function output_to_virt_lines(output)
  if not output then return {} end

  local mimetype = output.mimetype or "text/plain"
  local data = output.data

  if mimetype == "text/plain" then
    return render_text_plain(data)
  elseif mimetype == "application/vnd.marimo+error" then
    return render_error(data)
  elseif mimetype == "text/html" then
    return render_html(data)
  elseif mimetype == "application/vnd.dataresource+json" then
    return render_dataresource(data)
  elseif mimetype:match("^image/") then
    return { { { "  [image — open in browser to view]", "Comment" } } }
  elseif mimetype == "application/vnd.marimo+mime" then
    -- Rich marimo output; show placeholder
    return { { { "  [marimo widget — open in browser to view]", "Comment" } } }
  else
    -- Unknown mime: try to render as text
    if type(data) == "string" then
      return render_text_plain(data)
    end
    return { { { "  [" .. mimetype .. "]", "Comment" } } }
  end
end

-- Status indicator line at the top of each cell's output area.
local function status_virt_line(status)
  local icons = {
    running = { "  ⟳ running", "MarimoStatusRunning" },
    queued  = { "  ⟳ queued",  "MarimoStatusRunning" },
    idle    = nil,  -- don't show idle status (it's the default)
    error   = { "  ✖ error",   "MarimoStatusError" },
  }
  local entry = icons[status or "idle"]
  if not entry then return nil end
  return { entry }
end

-- ── Public API ──────────────────────────────────────────────────────────────

-- Render (or clear) the output for a cell.
-- `cell` must have `.end_row` set correctly.
function M.render(bufnr, cell)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- Clear previous output marks for this cell's row range
  vim.api.nvim_buf_clear_namespace(
    bufnr, hl.ns_output,
    cell.start_row, cell.end_row + 1
  )

  local virt_lines = {}

  -- Status line (only for non-idle)
  local status_line = status_virt_line(cell.status)
  if status_line then
    table.insert(virt_lines, status_line)
  end

  -- Output content
  if cell.output then
    local output_lines = output_to_virt_lines(cell.output)
    -- Truncate if too long
    local shown = 0
    for _, vl in ipairs(output_lines) do
      if shown >= MAX_LINES then
        table.insert(virt_lines, { { "  … (output truncated, open in browser for full view)", "Comment" } })
        break
      end
      table.insert(virt_lines, vl)
      shown = shown + 1
    end
  end

  -- Console output (stdout/stderr printed during execution)
  if cell.console and #cell.console > 0 then
    for _, cout in ipairs(cell.console) do
      if cout.data and cout.data ~= "" then
        local console_lines = render_text_plain(cout.data)
        for _, vl in ipairs(console_lines) do
          table.insert(virt_lines, vl)
        end
      end
    end
  end

  if #virt_lines == 0 then return end

  -- Attach at end_row so the output moves with the cell as it grows
  vim.api.nvim_buf_set_extmark(bufnr, hl.ns_output, cell.end_row, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
    priority = 90,
  })
end

-- Clear output for a specific cell.
function M.clear(bufnr, cell)
  cell.output = nil
  cell.console = nil
  cell.status = "idle"
  M.render(bufnr, cell)
end

-- Clear output for all cells.
function M.clear_all(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, hl.ns_output, 0, -1)
end

-- Handle an incoming cell-op WebSocket message.
-- Updates the cell's status and output, then re-renders.
function M.handle_cell_op(bufnr, nb, msg)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local cell_id = msg.cell_id
  if not cell_id then return end

  -- Find the cell by its server-assigned ID (nb.cell_by_id) or by scanning
  local cell = nb.cell_by_id[cell_id]
  if not cell then
    -- Unknown cell IDs almost always mean our ID mapping is out of sync with
    -- the server's (kernel-ready didn't re-key, or marimo registered cells
    -- under different IDs at /run time). Warn once per ID so the user can
    -- see what's happening instead of just watching "queued" forever.
    nb._unknown_cell_ids = nb._unknown_cell_ids or {}
    if not nb._unknown_cell_ids[cell_id] then
      nb._unknown_cell_ids[cell_id] = true
      local known = {}
      for id, _ in pairs(nb.cell_by_id) do table.insert(known, id) end
      vim.notify(
        "[neo-marimo] cell-op for unknown cell '" .. cell_id
          .. "'. Known: " .. table.concat(known, ", "),
        vim.log.levels.WARN
      )
    end
    return
  end

  -- Update status
  if msg.status then
    cell.status = msg.status
  end

  -- Update output (only replace if a new output is provided)
  if msg.output then
    cell.output = msg.output
  end

  -- Accumulate console output (list = replace, single = append)
  if msg.console then
    if type(msg.console) == "table" and #msg.console == 0 then
      -- Empty list = clear console
      cell.console = nil
    elseif type(msg.console) == "table" and msg.console[1] and msg.console[1].channel then
      -- It's already a list of CellOutput objects
      cell.console = msg.console
    else
      -- Single CellOutput
      cell.console = cell.console or {}
      table.insert(cell.console, msg.console)
    end
  end

  -- Re-render output for this cell
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.render(bufnr, cell)
    end
  end)
end

return M

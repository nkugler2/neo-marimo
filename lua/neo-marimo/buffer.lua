local hl = require("neo-marimo.highlights")
local cell_mod = require("neo-marimo.cell")
local config = require("neo-marimo.config")

local M = {}

-- Width used for cell border lines
local BORDER_WIDTH = 72

-- Build the top border virtual line for a cell.
-- Returns a list of {text, hl_group} chunks.
local function make_top_border(cell, border_hl, label_hl, opts)
  local style = opts.border_style or "rounded"

  if style == "none" then
    return {}
  end

  local type_labels = {
    python = " py ",
    markdown = " md ",
    sql = " sql ",
  }
  local type_label = type_labels[cell.type] or " py "

  -- Build label: "[py] name" or just "[py]"
  local label = type_label
  if opts.show_cell_name and cell.name ~= "_" and cell.name ~= "" then
    label = label .. cell.name .. " "
  end
  if opts.show_cell_index then
    label = label .. "#" .. tostring(cell.index) .. " "
  end
  if cell_mod.is_disabled(cell) then
    label = label .. "disabled "
  end

  -- Pad label with dashes to fill BORDER_WIDTH
  local corner_l = style == "rounded" and "╭" or "┌"
  local corner_r = style == "rounded" and "╮" or "┐"
  local dash = "─"

  local label_len = vim.fn.strwidth(label)
  local prefix_dashes = 1
  local suffix_len = BORDER_WIDTH - 2 - prefix_dashes - label_len
  if suffix_len < 1 then suffix_len = 1 end
  local suffix_dashes = string.rep(dash, suffix_len)

  local chunks = {
    { corner_l,                            border_hl },
    { string.rep(dash, prefix_dashes),     border_hl },
    { label,                               label_hl },
    { suffix_dashes,                       border_hl },
    { corner_r,                            border_hl },
  }

  return chunks
end

-- Build the bottom border virtual line for a cell.
local function make_bot_border(border_hl, opts)
  local style = opts.border_style or "rounded"

  if style == "none" then
    return {}
  end

  local corner_l = style == "rounded" and "╰" or "└"
  local corner_r = style == "rounded" and "╯" or "┘"
  local dash = "─"

  local dashes = string.rep(dash, BORDER_WIDTH - 2)
  return {
    { corner_l, border_hl },
    { dashes,   border_hl },
    { corner_r, border_hl },
  }
end

-- Place extmarks for a single cell's borders.
local function render_cell_borders(bufnr, cell)
  local ui = config.options.ui or {}
  local border_hl, label_hl = hl.type_hls(cell.type)

  -- Clear old border marks for this cell
  if cell.top_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, hl.ns_border, cell.top_mark_id)
  end
  if cell.bot_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, hl.ns_border, cell.bot_mark_id)
  end

  local top_chunks = make_top_border(cell, border_hl, label_hl, ui)
  local bot_chunks = make_bot_border(border_hl, ui)

  -- Top border: virtual line ABOVE start_row
  if #top_chunks > 0 then
    cell.top_mark_id = vim.api.nvim_buf_set_extmark(bufnr, hl.ns_border, cell.start_row, 0, {
      virt_lines = { top_chunks },
      virt_lines_above = true,
      priority = 100,
    })
  end

  -- Bottom border: virtual line AFTER end_row
  if #bot_chunks > 0 then
    cell.bot_mark_id = vim.api.nvim_buf_set_extmark(bufnr, hl.ns_border, cell.end_row, 0, {
      virt_lines = { bot_chunks },
      virt_lines_above = false,
      priority = 100,
    })
  end
end

-- Re-render borders for all cells. Call this after any structural change.
function M.render_all_borders(bufnr, nb)
  -- Clear entire border namespace first
  vim.api.nvim_buf_clear_namespace(bufnr, hl.ns_border, 0, -1)

  for _, cell in ipairs(nb.cells) do
    cell.top_mark_id = nil
    cell.bot_mark_id = nil
    render_cell_borders(bufnr, cell)
  end
end

-- Update borders for a single cell (e.g., after its row changed).
function M.render_cell_border(bufnr, cell)
  render_cell_borders(bufnr, cell)
end

-- Build the buffer lines from the notebook cells.
-- Returns a flat list of strings (no decorator boilerplate).
local function cells_to_lines(nb)
  local lines = {}
  for i, cell in ipairs(nb.cells) do
    local cell_lines = vim.split(cell.code, "\n", { plain = true })
    -- Ensure at least one line per cell (empty cells have one empty line)
    if #cell_lines == 0 then
      cell_lines = { "" }
    end
    local start_row = #lines  -- 0-indexed
    for _, line in ipairs(cell_lines) do
      table.insert(lines, line)
    end
    local end_row = #lines - 1  -- 0-indexed
    nb.cells[i].start_row = start_row
    nb.cells[i].end_row = end_row
  end
  return lines
end

-- Create the notebook view buffer from a notebook state.
-- Returns bufnr of the created buffer.
function M.create(nb, source_bufnr)
  local bufnr = vim.api.nvim_create_buf(false, true)

  -- Make it look and behave like a real file buffer
  vim.api.nvim_set_option_value("buftype", "acwrite", { buf = bufnr })
  vim.api.nvim_set_option_value("filetype", "python", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })

  -- Set a meaningful buffer name (shown in statusline)
  local fname = vim.fn.fnamemodify(nb.filepath, ":t")
  vim.api.nvim_buf_set_name(bufnr, "marimo://" .. nb.filepath)

  -- Populate buffer with cell content
  local lines = cells_to_lines(nb)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modified", false, { buf = bufnr })

  -- Render cell borders as virtual lines
  M.render_all_borders(bufnr, nb)

  nb.bufnr = bufnr

  return bufnr
end

-- Read current buffer lines and extract per-cell code.
-- Updates each cell's .code field and recomputes row offsets.
-- `nb.cells` line counts must already be known or we re-derive them.
function M.sync_cells_from_buffer(nb)
  local bufnr = nb.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local total = #all_lines

  -- We need to know the line-count per cell. The row offsets stored on cells
  -- are the source of truth (maintained by recompute_offsets_from_delta).
  for i, cell in ipairs(nb.cells) do
    local s = cell.start_row + 1     -- 1-indexed for slice
    local e = cell.end_row + 1
    if s < 1 then s = 1 end
    if e > total then e = total end

    if s > e then
      cell.code = ""
    else
      local cell_lines = {}
      for row = s, e do
        table.insert(cell_lines, all_lines[row])
      end
      cell.code = table.concat(cell_lines, "\n")
    end

    -- Update type detection in case user changed cell type
    cell.type = cell_mod.detect_type(cell.code)
  end

  return true
end

-- Called from TextChanged autocmd. Figures out which cell changed and
-- updates row offsets accordingly.
-- `bufnr`: the notebook buffer
-- `nb`: notebook state
function M.on_text_changed(bufnr, nb)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)

  -- Sum of stored line counts per cell
  local stored_total = 0
  local line_counts = {}
  for i, cell in ipairs(nb.cells) do
    local lc = cell.end_row - cell.start_row + 1
    line_counts[i] = lc
    stored_total = stored_total + lc
  end

  local delta = total_lines - stored_total
  if delta == 0 then
    -- No structural change in line count; update cell types but no reflow needed
    M.sync_cells_from_buffer(nb)
    return
  end

  -- Find the cell containing the cursor
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
  local changed_idx = 1
  for i, cell in ipairs(nb.cells) do
    if cursor_row >= cell.start_row then
      changed_idx = i
    end
  end

  -- Apply delta to the changed cell and shift all subsequent cells
  line_counts[changed_idx] = line_counts[changed_idx] + delta
  if line_counts[changed_idx] < 1 then
    line_counts[changed_idx] = 1
  end

  -- Recompute all offsets from line counts
  local row = 0
  for i, cell in ipairs(nb.cells) do
    local lc = line_counts[i]
    cell.start_row = row
    cell.end_row = row + lc - 1
    row = cell.end_row + 1
  end

  -- Re-render borders at new positions
  M.render_all_borders(bufnr, nb)
  nb.dirty = true
end

return M

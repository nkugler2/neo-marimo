local hl = require("neo-marimo.highlights")
local cell_mod = require("neo-marimo.cell")
local config = require("neo-marimo.config")

local M = {}

-- Minimum usable border width. Below this we just stop drawing dashes rather
-- than producing wrapped/broken borders.
local MIN_BORDER_WIDTH = 40

-- Fallback width used when the buffer isn't displayed in any window yet
-- (e.g. during initial create before nvim_win_set_buf runs).
local FALLBACK_BORDER_WIDTH = 72

-- Compute the visible text width for a buffer, accounting for sign column,
-- number column, and fold column. Returns FALLBACK_BORDER_WIDTH if the buffer
-- isn't in any window.
function M.border_width(bufnr)
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    return FALLBACK_BORDER_WIDTH
  end
  local winid = wins[1]
  local total = vim.api.nvim_win_get_width(winid)
  local info = vim.fn.getwininfo(winid)[1]
  local textoff = (info and info.textoff) or 0
  local width = total - textoff
  if width < MIN_BORDER_WIDTH then width = MIN_BORDER_WIDTH end
  return width
end

-- Apply soft-wrap and related window-local options to a window showing the
-- notebook buffer. Idempotent; safe to call from BufWinEnter.
function M.apply_window_settings(winid)
  local ui = config.options.ui or {}
  local wrap_on = ui.wrap_cells ~= false
  vim.api.nvim_set_option_value("wrap", wrap_on, { win = winid })
  if wrap_on then
    vim.api.nvim_set_option_value("linebreak", true, { win = winid })
    vim.api.nvim_set_option_value("breakindent", true, { win = winid })
    vim.api.nvim_set_option_value("showbreak", "↳ ", { win = winid })
  end
end

-- Suppress on_bytes change tracking while running `fn`. Use this to wrap
-- any code-driven mutation (insert/delete/swap from actions or sync) so the
-- buffer-attach hook doesn't queue a delta that we've already accounted for
-- by hand. Uses a counter so nested calls are safe.
function M.with_suppressed_bytes(nb, fn)
  nb._suppress_on_bytes = (nb._suppress_on_bytes or 0) + 1
  local ok, err = pcall(fn)
  nb._suppress_on_bytes = nb._suppress_on_bytes - 1
  if not ok then error(err, 0) end
end

-- Build the top border virtual line for a cell.
-- Returns a list of {text, hl_group} chunks.
local function make_top_border(cell, border_hl, label_hl, opts, width)
  local style = opts.border_style or "rounded"

  if style == "none" then
    return {}
  end

  -- Cell-type labels. Nerd-font variants when ui.icons is on, plain ASCII
  -- otherwise. Glyphs: nf-fa-python, nf-md-language_markdown, nf-md-database,
  -- nf-md-meteor (marimo).
  local labels_icon = {
    python   = "  py ",
    markdown = "  md ",
    sql      = " 󰆼 sql ",
    marimo   = " 󰀘 mo ",
  }
  local labels_plain = {
    python   = " py ",
    markdown = " md ",
    sql      = " sql ",
    marimo   = " mo ",
  }
  local labels = (opts.icons == false) and labels_plain or labels_icon
  local type_label = labels[cell.type] or labels.python

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

  -- Pad label with dashes to fill the visible window width
  local corner_l = style == "rounded" and "╭" or "┌"
  local corner_r = style == "rounded" and "╮" or "┐"
  local dash = "─"

  local label_len = vim.fn.strwidth(label)
  local prefix_dashes = 1
  local suffix_len = width - 2 - prefix_dashes - label_len
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
local function make_bot_border(border_hl, opts, width)
  local style = opts.border_style or "rounded"

  if style == "none" then
    return {}
  end

  local corner_l = style == "rounded" and "╰" or "└"
  local corner_r = style == "rounded" and "╯" or "┘"
  local dash = "─"

  local inner = width - 2
  if inner < 1 then inner = 1 end
  local dashes = string.rep(dash, inner)
  return {
    { corner_l, border_hl },
    { dashes,   border_hl },
    { corner_r, border_hl },
  }
end

-- Place extmarks for a single cell's borders.
local function render_cell_borders(bufnr, cell, width)
  local ui = config.options.ui or {}
  local border_hl, label_hl = hl.type_hls(cell.type)
  width = width or M.border_width(bufnr)

  -- Clear old border marks for this cell
  if cell.top_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, hl.ns_border, cell.top_mark_id)
  end
  if cell.bot_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, hl.ns_border, cell.bot_mark_id)
  end

  local top_chunks = make_top_border(cell, border_hl, label_hl, ui, width)
  local bot_chunks = make_bot_border(border_hl, ui, width)

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

  local width = M.border_width(bufnr)
  for _, cell in ipairs(nb.cells) do
    cell.top_mark_id = nil
    cell.bot_mark_id = nil
    render_cell_borders(bufnr, cell, width)
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

-- Find the 1-based cell index containing `row` (0-indexed). Falls back to
-- the last cell if `row` sits past the final cell (e.g. trailing-newline
-- inserts) and the first cell if it sits before the first.
local function cell_index_at_row(nb, row)
  for i, cell in ipairs(nb.cells) do
    if row >= cell.start_row and row <= cell.end_row then
      return i
    end
  end
  if #nb.cells == 0 then return nil end
  if row < nb.cells[1].start_row then return 1 end
  return #nb.cells
end

-- Apply a list of byte-level changes (captured by nvim_buf_attach's
-- on_bytes hook) to the notebook's cell row offsets, then re-sync code
-- and re-render borders.
--
-- `changes` is an ordered list of { start_row = ..., delta = ... } where
-- `delta = new_end_row - old_end_row` — i.e. how many rows the change added
-- (positive) or removed (negative). `start_row` is the row position *before*
-- the change in 0-indexed buffer coordinates, which is exactly the row whose
-- containing cell should absorb the delta.
--
-- Walking changes in order matters: each delta shifts subsequent cells,
-- so later changes need to be located against the updated offsets.
function M.on_bytes_changed(bufnr, nb, changes)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  for _, change in ipairs(changes) do
    local delta = change.delta
    if delta ~= 0 then
      local idx = cell_index_at_row(nb, change.start_row)
      if idx then
        local cell = nb.cells[idx]
        cell.end_row = cell.end_row + delta
        if cell.end_row < cell.start_row then
          cell.end_row = cell.start_row
        end
        for j = idx + 1, #nb.cells do
          nb.cells[j].start_row = nb.cells[j].start_row + delta
          nb.cells[j].end_row = nb.cells[j].end_row + delta
        end
      end
    end
  end

  -- Refresh code text + cell-type detection from the new buffer state.
  M.sync_cells_from_buffer(nb)

  -- Re-render borders at the new positions.
  M.render_all_borders(bufnr, nb)
  nb.dirty = true
end

return M

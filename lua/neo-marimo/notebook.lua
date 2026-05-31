local cell_mod = require("neo-marimo.cell")
local utils = require("neo-marimo.utils")

local M = {}

-- Create a new notebook state from parsed data.
-- `data` is what parser.parse_file returns.
-- `filepath` is the absolute path to the .py file.
function M.new(filepath, data)
  local nb = {
    filepath = filepath,
    version = data.version,
    app_options = data.app_options or {},
    cells = {},           -- ordered list of cell tables
    cell_by_id = {},      -- id -> cell
    dirty = false,
    bufnr = nil,          -- set after buffer is created
    server_url = nil,     -- set when server connects
    session_id = nil,
  }

  for i, raw in ipairs(data.cells or {}) do
    local c = cell_mod.new(raw, i)
    table.insert(nb.cells, c)
    nb.cell_by_id[c.id] = c
  end

  return nb
end

-- Find the cell whose [start_row, end_row] contains `row` (0-indexed).
-- Returns the cell table or nil.
function M.get_cell_at_row(nb, row)
  for _, c in ipairs(nb.cells) do
    if row >= c.start_row and row <= c.end_row then
      return c
    end
  end
  return nil
end

-- Find the 1-based index of a cell in nb.cells by its ID.
function M.cell_index(nb, cell_id)
  for i, c in ipairs(nb.cells) do
    if c.id == cell_id then
      return i
    end
  end
  return nil
end

-- Insert a new blank cell after the cell at `after_index` (1-based).
-- Adjusts row offsets for subsequent cells.
-- Returns the new cell.
function M.insert_cell_after(nb, after_index)
  local new_cell = cell_mod.new({ name = "_", code = "" }, after_index + 1)

  -- Insert into list
  table.insert(nb.cells, after_index + 1, new_cell)

  -- Re-number indices
  for i, c in ipairs(nb.cells) do
    c.index = i
  end

  nb.cell_by_id[new_cell.id] = new_cell
  nb.dirty = true
  return new_cell
end

-- Insert a new blank cell before the cell at `before_index` (1-based).
function M.insert_cell_before(nb, before_index)
  local new_cell = cell_mod.new({ name = "_", code = "" }, before_index)

  table.insert(nb.cells, before_index, new_cell)

  for i, c in ipairs(nb.cells) do
    c.index = i
  end

  nb.cell_by_id[new_cell.id] = new_cell
  nb.dirty = true
  return new_cell
end

-- Delete the cell at `idx` (1-based). Returns the deleted cell.
function M.delete_cell(nb, idx)
  if #nb.cells <= 1 then
    utils.warn("Cannot delete the only cell in a notebook.")
    return nil
  end
  local c = table.remove(nb.cells, idx)
  nb.cell_by_id[c.id] = nil

  for i, cell in ipairs(nb.cells) do
    cell.index = i
  end

  nb.dirty = true
  return c
end

-- Move the cell at `idx` down one position (swaps with idx+1).
function M.move_cell_down(nb, idx)
  if idx >= #nb.cells then return false end
  nb.cells[idx], nb.cells[idx + 1] = nb.cells[idx + 1], nb.cells[idx]
  nb.cells[idx].index = idx
  nb.cells[idx + 1].index = idx + 1
  nb.dirty = true
  return true
end

-- Move the cell at `idx` up one position (swaps with idx-1).
function M.move_cell_up(nb, idx)
  if idx <= 1 then return false end
  nb.cells[idx], nb.cells[idx - 1] = nb.cells[idx - 1], nb.cells[idx]
  nb.cells[idx].index = idx
  nb.cells[idx - 1].index = idx - 1
  nb.dirty = true
  return true
end

-- Recompute start_row and end_row for all cells based on current buffer state.
-- `line_counts` is an array matching nb.cells with the current line count per cell.
function M.recompute_offsets(nb, line_counts)
  local row = 0
  for i, c in ipairs(nb.cells) do
    local lc = line_counts[i] or cell_mod.line_count(c)
    c.start_row = row
    c.end_row = row + lc - 1
    row = c.end_row + 1
  end
end

return M

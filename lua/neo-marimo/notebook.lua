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
  line_counts = line_counts or {}
  local row = 0
  for i, c in ipairs(nb.cells) do
    local lc = line_counts[i] or cell_mod.line_count(c)
    c.start_row = row
    c.end_row = row + lc - 1
    row = c.end_row + 1
  end
end

-- Drop cells that have no surviving buffer rows. Two shapes show up:
--   1) end_row < start_row — the cell's range collapsed (e.g. `dd` on the
--      only line of an empty cell, then the byte-tracker shifted neighbours
--      up without removing this cell).
--   2) start_row <= prev.end_row — the cell overlaps the previous cell.
--      When two cells claim the same rows, the buffer only actually has one
--      cell's worth of content there; the empty/phantom cell is the one to
--      drop. If both are non-empty we leave them and let validate_offsets
--      surface the problem instead of guessing.
-- Returns the number of cells removed.
function M.prune_phantoms(nb)
  local removed = 0
  local i = 1
  while i <= #nb.cells do
    local cell = nb.cells[i]
    local kill = false
    if cell.end_row < cell.start_row then
      kill = true
    elseif i > 1 then
      local prev = nb.cells[i - 1]
      if cell.start_row <= prev.end_row then
        -- Overlap. Drop whichever side is empty; if both are empty drop
        -- this one (arbitrary but deterministic); if both non-empty leave
        -- them for the validator.
        local cell_empty = (cell.code or "") == ""
        local prev_empty = (prev.code or "") == ""
        if cell_empty then
          kill = true
        elseif prev_empty then
          nb.cell_by_id[prev.id] = nil
          table.remove(nb.cells, i - 1)
          removed = removed + 1
          -- Don't increment i; the new cell at i is the one we just
          -- looked at, and its prev is the new i-1.
          for k, c in ipairs(nb.cells) do c.index = k end
          goto continue
        end
      end
    end
    if kill then
      nb.cell_by_id[cell.id] = nil
      table.remove(nb.cells, i)
      removed = removed + 1
      for k, c in ipairs(nb.cells) do c.index = k end
    else
      i = i + 1
    end
    ::continue::
  end
  return removed
end

-- Try to match an on_bytes change set against a recently-trashed cell
-- (`nb._undo_trash`, populated by the `<leader>md` handler). If the user
-- just did `<leader>md` then `u`, vim restores the deleted rows and on_bytes
-- fires with a single +N insertion at the same row the cell originally
-- occupied. Splice the cell back into nb.cells with its original id and
-- consume the matching change so on_bytes_changed doesn't double-count.
--
-- Returns the (possibly shortened) change list. The buffer state is already
-- correct when this runs (vim restored it); only the model needs updating.
function M.try_undo_restore(nb, changes)
  if not nb._undo_trash or #nb._undo_trash == 0 then return changes end
  if #changes == 0 then return changes end

  local now = vim.uv.hrtime() / 1e6
  local TTL = 60000
  local cell_mod = require("neo-marimo.cell")
  local buffer = require("neo-marimo.buffer")
  local filtered = {}

  for _, change in ipairs(changes) do
    local matched = false
    if change.delta > 0 then
      for ti, t in ipairs(nb._undo_trash) do
        if (now - t.trashed_at) > TTL then
          -- entry is too old; leave it for the LRU eviction below
        elseif t.start_row == change.start_row
            and t.line_count == change.delta then
          -- delta is `new_end_row - old_end_row`; for an insertion of N
          -- whole rows it equals N. line_count is the cell's prior row
          -- count, which is exactly the number of rows vim re-inserts.
          local restored = cell_mod.new({
            id = t.id, name = t.name, code = t.code, options = t.options,
          }, 0)
          restored.status = t.status or "idle"
          restored.output = t.output
          restored.console = t.console
          if t.type then restored.type = t.type end

          local insert_idx = 1
          for j, c in ipairs(nb.cells) do
            if c.start_row >= t.start_row then break end
            insert_idx = j + 1
          end
          table.insert(nb.cells, insert_idx, restored)
          nb.cell_by_id[restored.id] = restored
          for k, c in ipairs(nb.cells) do c.index = k end
          if nb.bufnr and vim.api.nvim_buf_is_valid(nb.bufnr) then
            -- Place a fresh anchor at the row vim just restored. Other
            -- cells' anchors already moved themselves via gravity, so a
            -- post-anchor sync picks up the new contiguous layout.
            buffer.place_cell_anchor(nb.bufnr, restored, t.start_row)
            buffer.sync_cells_from_extmarks(nb.bufnr, nb)
          else
            M.recompute_offsets(nb)
          end

          table.remove(nb._undo_trash, ti)
          matched = true
          break
        end
      end
    end
    if not matched then table.insert(filtered, change) end
  end

  -- Drop expired trash so it can't shadow a future legitimate match.
  for i = #nb._undo_trash, 1, -1 do
    if (now - nb._undo_trash[i].trashed_at) > TTL then
      table.remove(nb._undo_trash, i)
    end
  end

  return filtered
end

-- Walk nb.cells and check three invariants that, when violated, cause the
-- "stacked borders / multiple `py #N` labels on the same row" visual bug:
--   1) cells[1].start_row == 0
--   2) cells[i].end_row + 1 == cells[i+1].start_row (no overlap, no gap)
--   3) sum of cell line counts == nvim_buf_line_count(bufnr)
-- Returns `ok, errors` where errors is a list of human-readable strings.
-- `bufnr` is optional; if omitted, invariant (3) is skipped.
function M.validate_offsets(nb, bufnr)
  local errors = {}

  if #nb.cells == 0 then
    return true, errors
  end

  if nb.cells[1].start_row ~= 0 then
    table.insert(errors, string.format(
      "cells[1].start_row = %d, expected 0",
      nb.cells[1].start_row))
  end

  for i, c in ipairs(nb.cells) do
    if c.end_row < c.start_row then
      table.insert(errors, string.format(
        "cell[%d] (id=%s): end_row=%d < start_row=%d",
        i, tostring(c.id), c.end_row, c.start_row))
    end
    if i < #nb.cells then
      local next_c = nb.cells[i + 1]
      if c.end_row + 1 ~= next_c.start_row then
        table.insert(errors, string.format(
          "gap/overlap between cell[%d] (end_row=%d) and cell[%d] (start_row=%d)",
          i, c.end_row, i + 1, next_c.start_row))
      end
    end
  end

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local buf_lines = vim.api.nvim_buf_line_count(bufnr)
    local last = nb.cells[#nb.cells]
    local cells_lines = last.end_row + 1
    if cells_lines ~= buf_lines then
      table.insert(errors, string.format(
        "cells cover %d rows but buffer has %d lines",
        cells_lines, buf_lines))
    end
  end

  return #errors == 0, errors
end

return M

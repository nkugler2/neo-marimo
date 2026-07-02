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
--
-- This sweep never prunes the notebook down to zero cells (mirrors
-- delete_cell's floor of 1, notebook.lua:77-91): a compound delete that
-- collapses *every* remaining cell's range in one buffer edit would
-- otherwise walk this loop to `nb.cells == {}`, and nothing re-seeds it
-- afterward — sync.write_to_file and marimo both assume >=1 cell exists
-- (plan-refinement F1.5). If a single cell is left, it's kept as-is even if
-- it still looks collapsed. If pruning would otherwise wipe out every
-- candidate in one pass, one is picked ahead of time to survive: the cell
-- with the most surviving lines (end_row - start_row; least-negative for a
-- fully collapsed range, ties broken by earliest original index) — a
-- "least-broken" placeholder beats an empty notebook, and validate_offsets
-- will still flag it for the user.
--
-- Note this guard only protects *this* sweep, run on whatever cells are
-- still standing by the time it's called. It does not by itself guarantee
-- the notebook is never emptied end-to-end: buffer.sync_cells_from_extmarks
-- runs its own dead-anchor sweep first (removing cells whose extmark vim
-- invalidated outright), which needed and now has an analogous
-- last-survivor guard of its own — see the comment there (plan-refinement
-- F1.5 finding #1). Both sweeps have to hold the line independently since
-- either one, run alone, could otherwise walk the notebook to zero cells.
-- Returns the number of cells removed.
function M.prune_phantoms(nb)
  if #nb.cells <= 1 then return 0 end

  local survivor_id = nb.cells[1].id
  local survivor_score = nb.cells[1].end_row - nb.cells[1].start_row
  for idx = 2, #nb.cells do
    local c = nb.cells[idx]
    local score = c.end_row - c.start_row
    if score > survivor_score then
      survivor_score = score
      survivor_id = c.id
    end
  end

  local removed = 0
  local i = 1
  while i <= #nb.cells do
    if #nb.cells <= 1 then break end
    local cell = nb.cells[i]
    local kill = false
    if cell.id ~= survivor_id and cell.end_row < cell.start_row then
      kill = true
    elseif i > 1 then
      local prev = nb.cells[i - 1]
      if cell.start_row <= prev.end_row then
        -- Overlap. Drop whichever side is empty; if both are empty drop
        -- this one (arbitrary but deterministic); if both non-empty leave
        -- them for the validator. The designated survivor is never treated
        -- as the empty/droppable side here.
        local cell_empty = cell.id ~= survivor_id and (cell.code or "") == ""
        local prev_empty = prev.id ~= survivor_id and (prev.code or "") == ""
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

-- Bounded ring of cells deleted by any path. We hold onto enough state to
-- splice a cell back into nb.cells when the user undoes its deletion —
-- without this, vim restores the buffer rows but our model has lost the
-- original cell's id/options/output, and the restored rows get glued onto
-- whichever cell now occupies that position.
local UNDO_TRASH_CAP = 5

-- Monotonic counter identifying which single buffer edit ("batch") a trash
-- entry came from. try_undo_restore's contiguous-run matcher (below) only
-- grows a run within one batch — two entries from unrelated deletes must
-- never be spliced together just because their cached rows happen to end up
-- adjacent (plan-refinement F1.1 finding #2). Callers that push several
-- cells from the same edit (buffer.sync_cells_from_extmarks) call this once
-- and pass the same id to every push_undo_trash call for that edit; callers
-- that push a single cell in isolation (actions.delete_cell_at_cursor) can
-- omit it and push_undo_trash mints a fresh one per call.
function M.next_undo_batch(nb)
  nb._undo_batch_seq = (nb._undo_batch_seq or 0) + 1
  return nb._undo_batch_seq
end

-- Snapshot `cell` onto nb._undo_trash so try_undo_restore can splice it back
-- on undo. Every delete path pushes through here — the delete-cell action and
-- both sweeps in buffer.sync_cells_from_extmarks (dead anchor, collapsed
-- range) — so the entry shape can't drift between call sites.
--
-- `start_row` is optional and defaults to cell.start_row. Callers must pass
-- it explicitly when a *contiguous run* of cells collapses in the same
-- buffer edit (e.g. `V2jd` over 3 one-line cells): vim's anchors for all of
-- them collapse onto the same post-delete row, so by the time
-- sync_cells_from_extmarks notices the collapse, cell.start_row has already
-- been overwritten to that shared row for every cell in the run — pushing
-- that value would give b/c/d identical, wrong start_rows instead of their
-- true original 1/2/3, and the contiguous-run match in try_undo_restore
-- would never find them. The caller snapshots each cell's start_row before
-- the anchor-read pass mutates it and passes that snapshot through here.
--
-- `batch_id` is likewise optional; see next_undo_batch above.
function M.push_undo_trash(nb, cell, start_row, batch_id)
  nb._undo_trash = nb._undo_trash or {}
  table.insert(nb._undo_trash, 1, {
    id = cell.id,
    name = cell.name,
    code = cell.code,
    options = cell.options,
    status = cell.status,
    output = cell.output,
    console = cell.console,
    type = cell.type,
    start_row = start_row or cell.start_row,
    line_count = cell_mod.line_count(cell),
    trashed_at = vim.uv.hrtime() / 1e6,
    batch_id = batch_id or M.next_undo_batch(nb),
  })
  while #nb._undo_trash > UNDO_TRASH_CAP do
    table.remove(nb._undo_trash)
  end
end

-- Try to match an on_bytes change set against recently-trashed cells
-- (`nb._undo_trash`, populated by push_undo_trash above). If the user
-- just did `<leader>md` then `u`, vim restores the deleted rows and on_bytes
-- fires with a single +N insertion at the same row the cell originally
-- occupied. Splice the cell(s) back into nb.cells with their original ids
-- and consume the matching change so on_bytes_changed doesn't double-count.
--
-- A multi-cell delete (e.g. `V2jd` spanning 3 cells) pushes one trash entry
-- per cell, but vim's undo restores the whole span as a *single* on_bytes
-- insertion whose delta is the combined line count — no single entry
-- matches it on its own. So below we also look for a contiguous run of
-- entries (by their original start_row/line_count, ascending) whose summed
-- line_count equals the delta and whose first start_row equals the
-- insertion row; matching a run splices every cell in the run back in
-- order instead of losing them into whichever cell now precedes the
-- restored rows (plan-refinement F1.1).
--
-- A run is only ever grown within a single push_undo_trash batch (see
-- next_undo_batch). Numeric row-adjacency alone isn't enough to prove two
-- entries came from the same delete: two unrelated single-cell deletes can
-- leave cached rows that happen to be adjacent, and a later, unrelated
-- insertion whose delta coincidentally equals their summed line_count would
-- otherwise splice both back as one fabricated run (plan-refinement F1.1
-- finding #2). Requiring a shared batch id closes that window.
--
-- Known limitation: this only works if no other edit happened between the
-- delete and the undo. An intervening edit shifts buffer rows, so the
-- trash entries' cached start_row no longer lines up with where vim
-- restores the text; the match fails, the restored rows fall through to
-- the generic sync path, and the cell comes back with a fresh id instead
-- of its original one. Not cheaply fixable (we'd need to track the trash
-- entries' rows through every subsequent edit, like a second set of
-- extmarks) so it's left as a known gap rather than solved here.
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

  -- Live (non-expired) trash entries sorted by original start_row, each
  -- carrying its index into nb._undo_trash so a matched run can be removed
  -- afterward without the indices shifting mid-removal. Ties on start_row
  -- (two entries pushed at the same cached row, e.g. by different batches)
  -- are broken by trashed_at so the ordering is deterministic — table.sort
  -- is not stable and an unstable order here could flip which entry the
  -- run-growth loop below considers "first" from one call to the next.
  local function live_entries()
    local live = {}
    for ti, t in ipairs(nb._undo_trash) do
      if (now - t.trashed_at) <= TTL then
        table.insert(live, { entry = t, trash_index = ti })
      end
    end
    table.sort(live, function(a, b)
      if a.entry.start_row == b.entry.start_row then
        return a.entry.trashed_at < b.entry.trashed_at
      end
      return a.entry.start_row < b.entry.start_row
    end)
    return live
  end

  for _, change in ipairs(changes) do
    local matched = false
    if change.delta > 0 then
      local live = live_entries()

      -- Greedily grow a contiguous run starting at change.start_row: each
      -- next entry's start_row must pick up exactly where the previous one
      -- left off (they were adjacent cells before the delete) AND share the
      -- first entry's batch id (they were trashed by the same edit — see
      -- next_undo_batch/push_undo_trash). `live` is sorted ascending, so
      -- once an entry breaks contiguity or batch nothing later can restart
      -- it — a later entry from the run's batch, if any, would already be
      -- unreachable once row order has moved past it.
      local run = {}
      local sum = 0
      for _, item in ipairs(live) do
        if #run == 0 then
          if item.entry.start_row == change.start_row then
            table.insert(run, item)
            sum = item.entry.line_count
          end
        else
          local last = run[#run].entry
          if item.entry.batch_id == last.batch_id
              and item.entry.start_row == last.start_row + last.line_count then
            table.insert(run, item)
            sum = sum + item.entry.line_count
          else
            break
          end
        end
        if sum >= change.delta then break end
      end

      if #run > 0 and sum == change.delta then
        -- delta is `new_end_row - old_end_row`; for an insertion of N
        -- whole rows it equals N. The run's summed line_count is exactly
        -- the number of rows vim re-inserts across all matched cells.
        --
        -- Compute where the run belongs once, against nb.cells as it
        -- stands before any of the run is inserted (inserting them one at
        -- a time and re-deriving the index from each other's still-unset
        -- start_row would misplace later cells in the run).
        local insert_idx = 1
        for j, c in ipairs(nb.cells) do
          if c.start_row >= run[1].entry.start_row then break end
          insert_idx = j + 1
        end

        for offset, item in ipairs(run) do
          local t = item.entry
          local restored = cell_mod.new({
            id = t.id, name = t.name, code = t.code, options = t.options,
          }, 0)
          restored.status = t.status or "idle"
          restored.output = t.output
          restored.console = t.console
          if t.type then restored.type = t.type end

          table.insert(nb.cells, insert_idx + offset - 1, restored)
          nb.cell_by_id[restored.id] = restored
          if nb.bufnr and vim.api.nvim_buf_is_valid(nb.bufnr) then
            -- Place a fresh anchor at the row vim just restored. Other
            -- cells' anchors already moved themselves via gravity, so a
            -- post-anchor sync picks up the new contiguous layout.
            buffer.place_cell_anchor(nb.bufnr, restored, t.start_row)
          end
        end
        for k, c in ipairs(nb.cells) do c.index = k end
        if nb.bufnr and vim.api.nvim_buf_is_valid(nb.bufnr) then
          buffer.sync_cells_from_extmarks(nb.bufnr, nb)
        else
          M.recompute_offsets(nb)
        end

        -- Remove matched entries highest-index-first so earlier removals
        -- don't shift the trash_index of ones still to be removed.
        table.sort(run, function(a, b) return a.trash_index > b.trash_index end)
        for _, item in ipairs(run) do
          table.remove(nb._undo_trash, item.trash_index)
        end
        matched = true
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

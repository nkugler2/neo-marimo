-- Notebook actions shared by keymaps and user commands.
--
-- Each function takes (bufnr, nb) and performs the same work the original
-- keymap closures did. Pulled out so :MarimoEdit / :MarimoRun / :MarimoNewCell
-- can invoke the same code paths without re-implementing them.

local notebook = require("neo-marimo.notebook")
local buffer = require("neo-marimo.buffer")
local server = require("neo-marimo.server")
local output = require("neo-marimo.output")
local sync = require("neo-marimo.sync")
local widgets = require("neo-marimo.widgets")
local highlights = require("neo-marimo.highlights")
local utils = require("neo-marimo.utils")

local M = {}

-- Persist pending edits so the running marimo server sees the same cells
-- we're about to ask it to run. Without this:
--   * New cells added via <leader>mn keep our locally-generated IDs.
--   * /api/kernel/run registers those IDs as ad-hoc cells on the server,
--     but the browser only renders cells it learned about via the reload
--     broadcast — so the browser shows the codes but not the run output,
--     and a dependent rerun in marimo emits cell-op for cells we never
--     learned about ("unknown cell" warnings).
-- Saving first triggers marimo's --watch reload, which broadcasts the
-- authoritative cell IDs via update-cell-ids; our handler re-keys, then
-- /api/kernel/run uses IDs both sides agree on.
--
-- The save → reload → update-cell-ids round trip is asynchronous, so we
-- block briefly (≤ 1.5s) on the update-cell-ids stamp catching up to
-- nb._last_save_at. With watchdog installed this is ~50ms and
-- imperceptible; with marimo's polling fallback it can hit the timeout,
-- which is still better than running with stale IDs.
local function flush_pending_edits(bufnr, nb, opts)
  opts = opts or {}
  local modified = vim.api.nvim_get_option_value("modified", { buf = bufnr })
  if not modified and not nb.dirty then return end

  if not sync.write_to_file(nb) then return end

  if opts.wait_for_reload == false then return end
  if not server.is_running(nb.filepath) then return end

  local saved_at = nb._last_save_at or 0
  vim.wait(1500, function()
    return (nb._last_cell_ids_at or 0) >= saved_at
  end, 25)
end

local function jump_to_cell(cell)
  if not cell then return end
  local row = cell.start_row + 1
  local line_count = vim.api.nvim_buf_line_count(0)
  if row > line_count then row = line_count end
  vim.api.nvim_win_set_cursor(0, { row, 0 })
end

-- Insert a blank cell after the cell containing the cursor (or at end of
-- notebook if the cursor isn't over any cell). Renders borders and jumps to
-- the new cell.
function M.new_cell_below(bufnr, nb)
  if nb._flush_pending then nb._flush_pending() end
  local new_cell
  buffer.with_suppressed_bytes(nb, function()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local cell = notebook.get_cell_at_row(nb, row)
    local idx = cell and cell.index or #nb.cells

    local insert_row = cell and (cell.end_row + 1) or vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, { "" })

    new_cell = notebook.insert_cell_after(nb, idx)
    -- Anchor the new cell at insert_row. The existing cells at and below
    -- have already been pushed down by extmark gravity from the set_lines
    -- call above, so insert_row is now the empty row we just created.
    buffer.place_cell_anchor(bufnr, new_cell, insert_row)
    buffer.refresh_after_mutation(bufnr, nb)
  end)
  jump_to_cell(new_cell)
end

-- Insert a blank cell before the cell containing the cursor (or at the top
-- if the cursor isn't over any cell).
function M.new_cell_above(bufnr, nb)
  if nb._flush_pending then nb._flush_pending() end
  local new_cell
  buffer.with_suppressed_bytes(nb, function()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local cell = notebook.get_cell_at_row(nb, row)
    local idx = cell and cell.index or 1

    local insert_row = cell and cell.start_row or 0
    vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, { "" })

    new_cell = notebook.insert_cell_before(nb, idx)
    buffer.place_cell_anchor(bufnr, new_cell, insert_row)
    buffer.refresh_after_mutation(bufnr, nb)
  end)
  jump_to_cell(new_cell)
end

-- Delete the cell containing the cursor. Snapshots the cell to undo trash
-- first so `u` can splice it back with its original id / options / cached
-- output (matched in buffer.attach_change_tracking's flush).
function M.delete_cell_at_cursor(bufnr, nb)
  if nb._flush_pending then nb._flush_pending() end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell = notebook.get_cell_at_row(nb, row)
  if not cell then return end

  -- Mirror notebook.delete_cell's guard up here: if we'd refuse to delete
  -- the only cell, also refuse to nuke its rows from the buffer. Running
  -- set_lines first and only then asking the notebook to drop the cell
  -- would leave the buffer empty while nb.cells still held the now-rowless
  -- cell.
  if #nb.cells <= 1 then
    utils.warn("Cannot delete the only cell in a notebook.")
    return
  end

  local idx = cell.index

  notebook.push_undo_trash(nb, cell)

  buffer.with_suppressed_bytes(nb, function()
    -- ns_output isn't wiped by render_all_borders (only ns_border is),
    -- so a "✓ ran" indicator anchored at the deleted cell's end_row
    -- would migrate onto the previous row when set_lines collapses the
    -- range, stacking on top of the previous cell's indicator. Clear it
    -- first.
    vim.api.nvim_buf_clear_namespace(
      bufnr, highlights.ns_output, cell.start_row, cell.end_row + 1
    )
    widgets.clear_for_cell(bufnr, cell.id)

    -- Drop the cell anchor before set_lines so vim doesn't try to
    -- move it to the collapsed range's boundary. A leftover anchor
    -- would attach to whichever cell now occupies the row, creating
    -- two overlapping anchors at the same position.
    buffer.clear_cell_anchor(bufnr, cell)

    -- Remove lines from buffer (0-indexed start, exclusive end)
    vim.api.nvim_buf_set_lines(bufnr, cell.start_row, cell.end_row + 1, false, {})

    notebook.delete_cell(nb, idx)

    -- The remaining cells' anchors moved themselves via extmark
    -- gravity; refresh_after_mutation does sync + prune + sync +
    -- render so any anchor that collided gets pruned before we paint.
    buffer.refresh_after_mutation(bufnr, nb)
  end)

  -- Move cursor to a valid position
  local target_idx = math.min(idx, #nb.cells)
  if target_idx >= 1 then
    jump_to_cell(nb.cells[target_idx])
  end
end

-- Swap the cell containing the cursor with the one below it.
function M.move_cell_down_at_cursor(bufnr, nb)
  if nb._flush_pending then nb._flush_pending() end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell = notebook.get_cell_at_row(nb, row)
  if not cell or cell.index >= #nb.cells then return end

  local idx = cell.index
  local next_cell = nb.cells[idx + 1]

  buffer.with_suppressed_bytes(nb, function()
    -- Swap lines in the buffer
    local cell_lines = vim.api.nvim_buf_get_lines(bufnr, cell.start_row, cell.end_row + 1, false)
    local next_lines = vim.api.nvim_buf_get_lines(bufnr, next_cell.start_row, next_cell.end_row + 1, false)
    -- Capture BEFORE the list_extend below — list_extend mutates its
    -- first argument in place, so #next_lines after the call would be
    -- (next_count + cell_count), which would push the moved cell's
    -- anchor too far down and its content would flow into the cell
    -- after it.
    local next_count = #next_lines
    local start_at = cell.start_row

    -- Drop both anchors before set_lines; we re-place them at the
    -- swapped positions below. Letting set_lines deal with anchors
    -- inside the replaced range would leave them at unpredictable
    -- positions.
    buffer.clear_cell_anchor(bufnr, cell)
    buffer.clear_cell_anchor(bufnr, next_cell)

    vim.api.nvim_buf_set_lines(bufnr, cell.start_row, next_cell.end_row + 1, false,
      vim.list_extend(next_lines, cell_lines))

    -- Swap in notebook state
    notebook.move_cell_down(nb, idx)

    local new_next = nb.cells[idx]      -- was next_cell, now at idx
    local new_cell = nb.cells[idx + 1]  -- was cell, now at idx+1

    buffer.place_cell_anchor(bufnr, new_next, start_at)
    buffer.place_cell_anchor(bufnr, new_cell, start_at + next_count)
    buffer.refresh_after_mutation(bufnr, nb)
  end)
  jump_to_cell(nb.cells[idx + 1])
end

-- Swap the cell containing the cursor with the one above it.
function M.move_cell_up_at_cursor(bufnr, nb)
  if nb._flush_pending then nb._flush_pending() end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell = notebook.get_cell_at_row(nb, row)
  if not cell or cell.index <= 1 then return end

  local idx = cell.index
  local prev_cell = nb.cells[idx - 1]

  buffer.with_suppressed_bytes(nb, function()
    local cell_lines = vim.api.nvim_buf_get_lines(bufnr, cell.start_row, cell.end_row + 1, false)
    local prev_lines = vim.api.nvim_buf_get_lines(bufnr, prev_cell.start_row, prev_cell.end_row + 1, false)
    -- Capture before list_extend mutates cell_lines (see
    -- move_cell_down_at_cursor for the same trap).
    local cell_count = #cell_lines
    local start_at = prev_cell.start_row

    buffer.clear_cell_anchor(bufnr, cell)
    buffer.clear_cell_anchor(bufnr, prev_cell)

    vim.api.nvim_buf_set_lines(bufnr, prev_cell.start_row, cell.end_row + 1, false,
      vim.list_extend(cell_lines, prev_lines))

    notebook.move_cell_up(nb, idx)

    local new_cell = nb.cells[idx - 1]
    local new_prev = nb.cells[idx]

    buffer.place_cell_anchor(bufnr, new_cell, start_at)
    buffer.place_cell_anchor(bufnr, new_prev, start_at + cell_count)
    buffer.refresh_after_mutation(bufnr, nb)
  end)
  jump_to_cell(nb.cells[idx - 1])
end

-- Start the marimo server (if needed) and open the notebook in the browser.
function M.open_in_browser(nb)
  server.start_and_open(nb, nb._on_ws_message)
end

local function require_server(nb)
  if not server.is_running(nb.filepath) then
    vim.notify("[neo-marimo] No server running. Press <leader>mo to start.", vim.log.levels.WARN)
    return false
  end
  return true
end

-- Run the cell under the cursor.
function M.run_cell_at_cursor(bufnr, nb)
  if not require_server(nb) then return end
  if nb._flush_pending then nb._flush_pending() end
  buffer.sync_cells_from_buffer(nb)
  flush_pending_edits(bufnr, nb)

  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell = notebook.get_cell_at_row(nb, row)
  if not cell then return end

  -- User-driven re-execution is the *only* place we clear widget value
  -- overrides for a cell. Auto-clearing on cell-op echoes was snapping
  -- sliders back to their parsed data-initial-value milliseconds after
  -- the user moved them via :MarimoWidget — see output.handle_cell_op.
  widgets.clear_overrides_for_cell(bufnr, cell.id)

  cell.status = "queued"
  output.render(bufnr, cell, nb.filepath)
  -- run_cells is async; if the request itself is rejected no cell-op will
  -- ever arrive, so roll the optimistic "queued" back rather than letting
  -- it spin forever.
  server.run_cells(nb.filepath, { cell.id }, { cell.code }, function(ok)
    if not ok and cell.status == "queued" then
      cell.status = "idle"
      output.render(bufnr, cell, nb.filepath)
    end
  end)
end

-- Run every cell in the notebook.
function M.run_all_cells(bufnr, nb)
  if not require_server(nb) then return end
  if nb._flush_pending then nb._flush_pending() end
  buffer.sync_cells_from_buffer(nb)
  flush_pending_edits(bufnr, nb)

  local cell_ids = {}
  local codes = {}
  for _, cell in ipairs(nb.cells) do
    table.insert(cell_ids, cell.id)
    table.insert(codes, cell.code)
    widgets.clear_overrides_for_cell(bufnr, cell.id)
    cell.status = "queued"
    output.render(bufnr, cell, nb.filepath)
  end

  server.run_cells(nb.filepath, cell_ids, codes, function(ok)
    if ok then return end
    for _, cell in ipairs(nb.cells) do
      if cell.status == "queued" then
        cell.status = "idle"
        output.render(bufnr, cell, nb.filepath)
      end
    end
  end)
end

return M

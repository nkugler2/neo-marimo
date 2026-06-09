local config = require("neo-marimo.config")
local notebook = require("neo-marimo.notebook")
local buffer = require("neo-marimo.buffer")
local server = require("neo-marimo.server")
local output = require("neo-marimo.output")
local actions = require("neo-marimo.actions")
local lsp = require("neo-marimo.lsp")
local dataframe = require("neo-marimo.dataframe")
local widgets = require("neo-marimo.widgets")
local highlights = require("neo-marimo.highlights")
local cell_mod = require("neo-marimo.cell")

-- Bounded ring of cells deleted via <leader>md. We hold onto enough state
-- to splice them back into nb.cells when the user undoes the deletion —
-- without this, vim restores the buffer rows but our model has lost the
-- original cell's id/options/output, and the restored rows get glued onto
-- whichever cell now occupies that position.
local UNDO_TRASH_CAP = 5

local function push_undo_trash(nb, cell)
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
    start_row = cell.start_row,
    line_count = cell_mod.line_count(cell),
    trashed_at = vim.uv.hrtime() / 1e6,
  })
  while #nb._undo_trash > UNDO_TRASH_CAP do
    table.remove(nb._undo_trash)
  end
end

local M = {}

-- Move cursor to the start of a cell
local function jump_to_cell(cell)
  if cell then
    -- +1 because nvim_win_set_cursor is 1-indexed
    local row = cell.start_row + 1
    local line_count = vim.api.nvim_buf_line_count(0)
    if row > line_count then row = line_count end
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end
end

-- Get the notebook state from a buffer (stored as buffer variable)
local function get_nb(bufnr)
  return vim.b[bufnr]._marimo_notebook
end

-- Set notebook state on buffer
local function set_nb(bufnr, nb)
  vim.b[bufnr]._marimo_notebook = nb
end

function M.setup(bufnr, nb)
  local km = config.options.keymaps
  if not km then return end

  local opts = { buffer = bufnr, silent = true, noremap = true }

  -- Helper to make a desc opts table
  local function o(desc)
    return vim.tbl_extend("force", opts, { desc = desc })
  end

  -- Next cell
  if km.next_cell then
    vim.keymap.set("n", km.next_cell, function()
      if nb._flush_pending then nb._flush_pending() end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if cell and cell.index < #nb.cells then
        jump_to_cell(nb.cells[cell.index + 1])
      end
    end, o("Marimo: next cell"))
  end

  -- Previous cell
  if km.prev_cell then
    vim.keymap.set("n", km.prev_cell, function()
      if nb._flush_pending then nb._flush_pending() end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if cell and cell.index > 1 then
        jump_to_cell(nb.cells[cell.index - 1])
      end
    end, o("Marimo: previous cell"))
  end

  -- New cell below
  if km.new_cell_below then
    vim.keymap.set("n", km.new_cell_below, function()
      actions.new_cell_below(bufnr, nb)
    end, o("Marimo: new cell below"))
  end

  -- New cell above
  if km.new_cell_above then
    vim.keymap.set("n", km.new_cell_above, function()
      actions.new_cell_above(bufnr, nb)
    end, o("Marimo: new cell above"))
  end

  -- Delete cell
  if km.delete_cell then
    vim.keymap.set("n", km.delete_cell, function()
      if nb._flush_pending then nb._flush_pending() end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if not cell then return end

      -- Mirror notebook.delete_cell's guard up here: if we'd refuse to
      -- delete the only cell, also refuse to nuke its rows from the buffer.
      -- The previous code ran set_lines first and only then asked the
      -- notebook to drop the cell, which left the buffer empty while
      -- nb.cells still held the now-rowless cell.
      if #nb.cells <= 1 then
        require("neo-marimo.utils").warn("Cannot delete the only cell in a notebook.")
        return
      end

      local idx = cell.index

      -- Snapshot the cell BEFORE we mutate the buffer so a subsequent `u`
      -- can splice it back with its original id / options / cached output.
      -- The matching happens in init.lua's flush_pending (the +N delta from
      -- vim's restore is paired against this trash entry).
      push_undo_trash(nb, cell)

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

        -- Remove lines from buffer (0-indexed start, exclusive end)
        vim.api.nvim_buf_set_lines(bufnr, cell.start_row, cell.end_row + 1, false, {})

        notebook.delete_cell(nb, idx)

        -- Rebuild row offsets from each remaining cell's code length instead
        -- of subtracting the deleted cell's line count from subsequent cells.
        -- The manual shift compounded any pre-existing offset drift (e.g.
        -- from a misattributed on_bytes delta) into overlapping ranges, which
        -- is what produced the "5 cells stacked on 2 rows" corruption that
        -- repeated deletes exhibited.
        --
        -- prune_phantoms is intentionally NOT called here. on_bytes_changed
        -- is the only path that can produce phantoms (post-byte-delta
        -- collapses); the action paths drive offsets directly so calling
        -- prune here would just risk dropping the cell we want to keep.
        notebook.recompute_offsets(nb)

        buffer.render_all_borders(bufnr, nb)
      end)

      -- Move cursor to a valid position
      local target_idx = math.min(idx, #nb.cells)
      if target_idx >= 1 then
        jump_to_cell(nb.cells[target_idx])
      end
    end, o("Marimo: delete cell"))
  end

  -- Move cell down
  if km.move_cell_down then
    vim.keymap.set("n", km.move_cell_down, function()
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

        vim.api.nvim_buf_set_lines(bufnr, cell.start_row, next_cell.end_row + 1, false,
          vim.list_extend(next_lines, cell_lines))

        -- Swap in notebook state
        notebook.move_cell_down(nb, idx)

        -- Fix row offsets: next_cell is now first, cell is second
        local new_next = nb.cells[idx]      -- was next_cell, now at idx
        local new_cell = nb.cells[idx + 1]  -- was cell, now at idx+1

        new_next.start_row = cell.start_row
        new_next.end_row = cell.start_row + #next_lines - 1
        new_cell.start_row = new_next.end_row + 1
        new_cell.end_row = new_cell.start_row + #cell_lines - 1

        buffer.render_all_borders(bufnr, nb)
      end)
      jump_to_cell(nb.cells[idx + 1])
    end, o("Marimo: move cell down"))
  end

  -- Move cell up
  if km.move_cell_up then
    vim.keymap.set("n", km.move_cell_up, function()
      if nb._flush_pending then nb._flush_pending() end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if not cell or cell.index <= 1 then return end

      local idx = cell.index
      local prev_cell = nb.cells[idx - 1]

      buffer.with_suppressed_bytes(nb, function()
        local cell_lines = vim.api.nvim_buf_get_lines(bufnr, cell.start_row, cell.end_row + 1, false)
        local prev_lines = vim.api.nvim_buf_get_lines(bufnr, prev_cell.start_row, prev_cell.end_row + 1, false)

        vim.api.nvim_buf_set_lines(bufnr, prev_cell.start_row, cell.end_row + 1, false,
          vim.list_extend(cell_lines, prev_lines))

        notebook.move_cell_up(nb, idx)

        local new_cell = nb.cells[idx - 1]
        local new_prev = nb.cells[idx]

        new_cell.start_row = prev_cell.start_row
        new_cell.end_row = prev_cell.start_row + #cell_lines - 1
        new_prev.start_row = new_cell.end_row + 1
        new_prev.end_row = new_prev.start_row + #prev_lines - 1

        buffer.render_all_borders(bufnr, nb)
      end)
      jump_to_cell(nb.cells[idx - 1])
    end, o("Marimo: move cell up"))
  end

  -- Open in browser (starts server if needed)
  if km.open_in_browser then
    vim.keymap.set("n", km.open_in_browser, function()
      actions.open_in_browser(nb)
    end, o("Marimo: start server and open in browser"))
  end

  -- Stop server
  if km.stop_server then
    vim.keymap.set("n", km.stop_server, function()
      server.stop(nb.filepath)
      output.clear_all(bufnr)
    end, o("Marimo: stop server"))
  end

  -- Run cell under cursor
  if km.run_cell then
    vim.keymap.set("n", km.run_cell, function()
      actions.run_cell_at_cursor(bufnr, nb)
    end, o("Marimo: run cell"))
  end

  -- Run all cells
  if km.run_all then
    vim.keymap.set("n", km.run_all, function()
      actions.run_all_cells(bufnr, nb)
    end, o("Marimo: run all cells"))
  end

  -- Toggle output visibility
  if km.toggle_output then
    vim.keymap.set("n", km.toggle_output, function()
      if nb._flush_pending then nb._flush_pending() end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if not cell then return end

      if cell._output_hidden then
        cell._output_hidden = false
        output.render(bufnr, cell)
      else
        cell._output_hidden = true
        vim.api.nvim_buf_clear_namespace(bufnr, require("neo-marimo.highlights").ns_output,
          cell.start_row, cell.end_row + 1)
      end
    end, o("Marimo: toggle cell output"))
  end

  -- Toggle between notebook view and underlying .py
  if km.toggle_view then
    vim.keymap.set("n", km.toggle_view, function()
      require("neo-marimo").toggle(bufnr)
    end, o("Marimo: toggle notebook view"))
  end

  -- Reclaim the WebSocket from the browser. After :MarimoEdit /
  -- <leader>mo we release the WS so the browser can connect; this
  -- takes it back so nvim resumes receiving cell-op messages.
  if km.reclaim_ws then
    vim.keymap.set("n", km.reclaim_ws, function()
      server.reclaim_ws(nb.filepath)
    end, o("Marimo: reclaim WebSocket from browser"))
  end

  -- LSP: hover, signature help, goto-definition, completion.
  -- Routed through a hidden shadow buffer (see lua/neo-marimo/lsp.lua).
  -- The default keymaps mirror nvim's built-in LSP defaults so muscle
  -- memory carries over from regular Python buffers.
  if km.hover ~= false then
    vim.keymap.set("n", km.hover or "K", function()
      lsp.hover()
    end, o("Marimo: hover (LSP)"))
  end

  if km.signature_help ~= false then
    vim.keymap.set("i", km.signature_help or "<C-k>", function()
      lsp.signature()
    end, o("Marimo: signature help (LSP)"))
  end

  if km.goto_definition ~= false then
    vim.keymap.set("n", km.goto_definition or "gd", function()
      lsp.goto_definition()
    end, o("Marimo: goto definition (LSP)"))
  end

  -- Wire <C-x><C-o> through our completefunc. The user's completion
  -- plugin (nvim-cmp, blink.cmp, coq, etc.) can also drive completion
  -- by calling neo_marimo_omnifunc(findstart, base) — most users will
  -- hit <C-x><C-o> directly, so setting omnifunc on the notebook
  -- buffer covers the default UX.
  if km.completion ~= false then
    vim.api.nvim_set_option_value(
      "omnifunc", "v:lua.neo_marimo_omnifunc",
      { buf = bufnr }
    )
  end

  -- Phase 8.5: DataFrame side-panel for the cell under the cursor.
  if km.dataframe_panel then
    vim.keymap.set("n", km.dataframe_panel, function()
      if nb._flush_pending then nb._flush_pending() end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if cell then dataframe.open_for_cell(nb, cell) end
    end, o("Marimo: open DataFrame side-panel"))
  end

  -- Phase 8.3: Widget interaction picker.
  if km.widget_picker then
    vim.keymap.set("n", km.widget_picker, function()
      if nb._flush_pending then nb._flush_pending() end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if not cell then return end
      require("neo-marimo.widget_picker").open(nb, cell)
    end, o("Marimo: interact with widgets in cell"))
  end
end

return M

local config = require("neo-marimo.config")
local notebook = require("neo-marimo.notebook")
local buffer = require("neo-marimo.buffer")
local sync = require("neo-marimo.sync")
local utils = require("neo-marimo.utils")

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
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      local idx = cell and cell.index or #nb.cells

      -- Insert blank line in buffer at cell.end_row + 1 (0-indexed → +1 for api)
      local insert_row = cell and (cell.end_row + 1) or vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, { "" })

      local new_cell = notebook.insert_cell_after(nb, idx)
      new_cell.start_row = insert_row
      new_cell.end_row = insert_row

      -- Shift subsequent cells down
      for i = idx + 2, #nb.cells do
        nb.cells[i].start_row = nb.cells[i].start_row + 1
        nb.cells[i].end_row = nb.cells[i].end_row + 1
      end

      buffer.render_all_borders(bufnr, nb)
      jump_to_cell(new_cell)
    end, o("Marimo: new cell below"))
  end

  -- New cell above
  if km.new_cell_above then
    vim.keymap.set("n", km.new_cell_above, function()
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      local idx = cell and cell.index or 1

      local insert_row = cell and cell.start_row or 0
      vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, { "" })

      local new_cell = notebook.insert_cell_before(nb, idx)
      new_cell.start_row = insert_row
      new_cell.end_row = insert_row

      -- Shift subsequent cells down (everything from idx onward, which is now idx+1)
      for i = idx + 1, #nb.cells do
        nb.cells[i].start_row = nb.cells[i].start_row + 1
        nb.cells[i].end_row = nb.cells[i].end_row + 1
      end

      buffer.render_all_borders(bufnr, nb)
      jump_to_cell(new_cell)
    end, o("Marimo: new cell above"))
  end

  -- Delete cell
  if km.delete_cell then
    vim.keymap.set("n", km.delete_cell, function()
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if not cell then return end

      local idx = cell.index
      local s = cell.start_row + 1  -- 1-indexed
      local e = cell.end_row + 1    -- 1-indexed (inclusive)
      local lc = e - s + 1

      -- Remove lines from buffer (0-indexed start, exclusive end)
      vim.api.nvim_buf_set_lines(bufnr, cell.start_row, cell.end_row + 1, false, {})

      notebook.delete_cell(nb, idx)

      -- Shift remaining cells up
      for i = idx, #nb.cells do
        nb.cells[i].start_row = nb.cells[i].start_row - lc
        nb.cells[i].end_row = nb.cells[i].end_row - lc
      end

      buffer.render_all_borders(bufnr, nb)

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
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if not cell or cell.index >= #nb.cells then return end

      local idx = cell.index
      local next_cell = nb.cells[idx + 1]

      -- Swap lines in the buffer
      local cell_lines = vim.api.nvim_buf_get_lines(bufnr, cell.start_row, cell.end_row + 1, false)
      local next_lines = vim.api.nvim_buf_get_lines(bufnr, next_cell.start_row, next_cell.end_row + 1, false)

      vim.api.nvim_buf_set_lines(bufnr, cell.start_row, next_cell.end_row + 1, false,
        vim.list_extend(next_lines, cell_lines))

      -- Swap in notebook state
      notebook.move_cell_down(nb, idx)

      -- Fix row offsets: next_cell is now first, cell is second
      local new_next = nb.cells[idx]   -- was next_cell, now at idx
      local new_cell = nb.cells[idx + 1] -- was cell, now at idx+1

      new_next.start_row = cell.start_row
      new_next.end_row = cell.start_row + #next_lines - 1
      new_cell.start_row = new_next.end_row + 1
      new_cell.end_row = new_cell.start_row + #cell_lines - 1

      buffer.render_all_borders(bufnr, nb)
      jump_to_cell(nb.cells[idx + 1])
    end, o("Marimo: move cell down"))
  end

  -- Move cell up
  if km.move_cell_up then
    vim.keymap.set("n", km.move_cell_up, function()
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if not cell or cell.index <= 1 then return end

      local idx = cell.index
      local prev_cell = nb.cells[idx - 1]

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
      jump_to_cell(nb.cells[idx - 1])
    end, o("Marimo: move cell up"))
  end

  -- Open in browser
  if km.open_in_browser then
    vim.keymap.set("n", km.open_in_browser, function()
      local marimo_cmd = config.options.marimo_cmd or "marimo"
      vim.fn.jobstart({ marimo_cmd, "edit", nb.filepath }, { detach = true })
      vim.notify("[neo-marimo] Opening in marimo browser...", vim.log.levels.INFO)
    end, o("Marimo: open in browser"))
  end

  -- Placeholder keymaps for Phase 2 (server execution)
  if km.run_cell then
    vim.keymap.set("n", km.run_cell, function()
      vim.notify("[neo-marimo] Cell execution requires server connection (Phase 2)", vim.log.levels.WARN)
    end, o("Marimo: run cell"))
  end

  if km.run_all then
    vim.keymap.set("n", km.run_all, function()
      vim.notify("[neo-marimo] Run all requires server connection (Phase 2)", vim.log.levels.WARN)
    end, o("Marimo: run all cells"))
  end
end

return M

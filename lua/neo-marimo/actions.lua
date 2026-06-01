-- Notebook actions shared by keymaps and user commands.
--
-- Each function takes (bufnr, nb) and performs the same work the original
-- keymap closures did. Pulled out so :MarimoEdit / :MarimoRun / :MarimoNewCell
-- can invoke the same code paths without re-implementing them.

local notebook = require("neo-marimo.notebook")
local buffer = require("neo-marimo.buffer")
local server = require("neo-marimo.server")
local output = require("neo-marimo.output")

local M = {}

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
  local new_cell
  buffer.with_suppressed_bytes(nb, function()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local cell = notebook.get_cell_at_row(nb, row)
    local idx = cell and cell.index or #nb.cells

    local insert_row = cell and (cell.end_row + 1) or vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, { "" })

    new_cell = notebook.insert_cell_after(nb, idx)
    new_cell.start_row = insert_row
    new_cell.end_row = insert_row

    for i = idx + 2, #nb.cells do
      nb.cells[i].start_row = nb.cells[i].start_row + 1
      nb.cells[i].end_row = nb.cells[i].end_row + 1
    end

    buffer.render_all_borders(bufnr, nb)
  end)
  jump_to_cell(new_cell)
end

-- Insert a blank cell before the cell containing the cursor (or at the top
-- if the cursor isn't over any cell).
function M.new_cell_above(bufnr, nb)
  local new_cell
  buffer.with_suppressed_bytes(nb, function()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local cell = notebook.get_cell_at_row(nb, row)
    local idx = cell and cell.index or 1

    local insert_row = cell and cell.start_row or 0
    vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, { "" })

    new_cell = notebook.insert_cell_before(nb, idx)
    new_cell.start_row = insert_row
    new_cell.end_row = insert_row

    for i = idx + 1, #nb.cells do
      nb.cells[i].start_row = nb.cells[i].start_row + 1
      nb.cells[i].end_row = nb.cells[i].end_row + 1
    end

    buffer.render_all_borders(bufnr, nb)
  end)
  jump_to_cell(new_cell)
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
  buffer.sync_cells_from_buffer(nb)

  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell = notebook.get_cell_at_row(nb, row)
  if not cell then return end

  cell.status = "queued"
  output.render(bufnr, cell)
  server.run_cells(nb.filepath, { cell.id }, { cell.code })
end

-- Run every cell in the notebook.
function M.run_all_cells(bufnr, nb)
  if not require_server(nb) then return end
  buffer.sync_cells_from_buffer(nb)

  local cell_ids = {}
  local codes = {}
  for _, cell in ipairs(nb.cells) do
    table.insert(cell_ids, cell.id)
    table.insert(codes, cell.code)
    cell.status = "queued"
    output.render(bufnr, cell)
  end

  server.run_cells(nb.filepath, cell_ids, codes)
end

return M

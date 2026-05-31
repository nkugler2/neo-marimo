local buffer = require("neo-marimo.buffer")
local parser = require("neo-marimo.parser")
local utils = require("neo-marimo.utils")
local config = require("neo-marimo.config")

local M = {}

-- Write the notebook state back to the .py file on disk.
-- Called from BufWriteCmd.
function M.write_to_file(nb)
  local bufnr = nb.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    utils.error("Cannot write: notebook buffer is no longer valid.")
    return false
  end

  -- Sync cell code from buffer content
  buffer.sync_cells_from_buffer(nb)

  -- Build cell list for the bridge
  local cells = {}
  for _, cell in ipairs(nb.cells) do
    table.insert(cells, {
      name = cell.name,
      code = cell.code,
      options = cell.options or {},
    })
  end

  -- Call Python bridge to generate .py source
  local ok, err = pcall(function()
    local py_source = parser.generate_py(cells, nb.filepath, config.options.python_path)
    local lines = vim.split(py_source, "\n", { plain = true })
    -- Remove trailing empty line if writefile would add one
    if lines[#lines] == "" then
      table.remove(lines)
    end
    vim.fn.writefile(lines, nb.filepath)
  end)

  if not ok then
    utils.error("Failed to write notebook: " .. tostring(err))
    return false
  end

  -- Mark buffer as unmodified
  vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
  nb.dirty = false

  vim.notify("[neo-marimo] Saved " .. vim.fn.fnamemodify(nb.filepath, ":t"), vim.log.levels.INFO)
  return true
end

-- Re-read the .py file and rebuild the notebook buffer.
-- Used when the file changes externally.
function M.reload_from_file(nb)
  local bufnr = nb.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local ok, data = pcall(parser.parse_file, nb.filepath, config.options.python_path)
  if not ok then
    utils.warn("Failed to reload notebook: " .. tostring(data))
    return false
  end

  -- Rebuild cells
  local cell_mod = require("neo-marimo.cell")
  nb.cells = {}
  nb.cell_by_id = {}
  for i, raw in ipairs(data.cells or {}) do
    local c = cell_mod.new(raw, i)
    table.insert(nb.cells, c)
    nb.cell_by_id[c.id] = c
  end

  -- Rewrite buffer content
  local lines = {}
  for i, cell in ipairs(nb.cells) do
    local cell_lines = vim.split(cell.code, "\n", { plain = true })
    if #cell_lines == 0 then cell_lines = { "" } end
    local start_row = #lines
    for _, l in ipairs(cell_lines) do
      table.insert(lines, l)
    end
    cell.start_row = start_row
    cell.end_row = #lines - 1
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modified", false, { buf = bufnr })

  buffer.render_all_borders(bufnr, nb)
  nb.dirty = false
  return true
end

return M

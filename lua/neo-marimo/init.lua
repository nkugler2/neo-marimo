local config = require("neo-marimo.config")
local parser = require("neo-marimo.parser")
local notebook = require("neo-marimo.notebook")
local buffer = require("neo-marimo.buffer")
local sync = require("neo-marimo.sync")
local keymaps = require("neo-marimo.keymaps")
local highlights = require("neo-marimo.highlights")
local utils = require("neo-marimo.utils")

local M = {}

-- Track active notebooks by source filepath to avoid double-attaching
local _attached = {}

-- Initialize the plugin with user options.
-- Call this from your Neovim config:
--   require("neo-marimo").setup({ python_path = "/path/to/python" })
function M.setup(opts)
  config.setup(opts)
  highlights.setup()
end

-- Check if a buffer's file is a marimo notebook.
-- Returns true if the buffer contains a marimo.App() instantiation.
function M.is_marimo_notebook(bufnr)
  -- Check filetype
  local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  if ft ~= "python" and ft ~= "" then
    return false
  end

  -- Check file extension
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name:match("%.py$") then
    return false
  end

  -- Read first 50 lines for marimo markers
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 50, false)
  local content = table.concat(lines, "\n")

  return content:find("marimo%.App%(") ~= nil
    or content:find("import marimo") ~= nil and content:find("@app%.cell") ~= nil
end

-- Attach the notebook view to a buffer.
-- This reads the file, creates the notebook buffer, and swaps the window.
function M.attach(source_bufnr)
  local filepath = vim.api.nvim_buf_get_name(source_bufnr)

  -- Avoid double-attaching
  if _attached[filepath] then
    -- Switch to the existing notebook buffer if it's still valid
    local existing_nb = _attached[filepath]
    if existing_nb.bufnr and vim.api.nvim_buf_is_valid(existing_nb.bufnr) then
      vim.api.nvim_win_set_buf(0, existing_nb.bufnr)
      return
    else
      _attached[filepath] = nil
    end
  end

  -- Parse the notebook file
  local python_path = config.options.python_path or "python3"
  local ok, data = pcall(parser.parse_file, filepath, python_path)
  if not ok then
    utils.warn("Failed to parse " .. filepath .. ": " .. tostring(data))
    utils.warn("Make sure python_path in setup() points to a Python with marimo installed.")
    utils.warn("Current python_path: " .. python_path)
    return
  end

  if not data.valid then
    local violations = data.violations or {}
    if #violations > 0 then
      utils.warn("Notebook has parse violations: " .. violations[1].description)
    end
    if not data.cells or #data.cells == 0 then
      utils.warn("No cells found in " .. filepath)
      return
    end
  end

  -- Build notebook state
  local nb = notebook.new(filepath, data)

  -- Create the visual notebook buffer
  local nb_bufnr = buffer.create(nb, source_bufnr)

  -- Store notebook state on the buffer (Lua value; cleared when buffer is wiped)
  -- We store it in our module-level table since vim.b can't hold Lua objects directly
  _attached[filepath] = nb

  -- Set up BufWriteCmd to intercept saves
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = nb_bufnr,
    callback = function()
      sync.write_to_file(nb)
    end,
  })

  -- Set up TextChanged to track edits (debounced)
  local on_changed = utils.debounce(function()
    if vim.api.nvim_buf_is_valid(nb_bufnr) then
      buffer.on_text_changed(nb_bufnr, nb)
    end
  end, 300)

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = nb_bufnr,
    callback = on_changed,
  })

  -- Clean up when notebook buffer is closed
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = nb_bufnr,
    once = true,
    callback = function()
      _attached[filepath] = nil
    end,
  })

  -- Switch the current window to show the notebook buffer
  vim.api.nvim_win_set_buf(0, nb_bufnr)

  -- Wipe the original source buffer (we no longer need it displayed)
  -- Use schedule to avoid issues with the autocmd still running
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(source_bufnr) and source_bufnr ~= nb_bufnr then
      pcall(vim.api.nvim_buf_delete, source_bufnr, { force = true })
    end
  end)

  -- Set up keymaps on the notebook buffer
  keymaps.setup(nb_bufnr, nb)

  local cell_count = #nb.cells
  vim.notify(
    string.format("[neo-marimo] Opened %s (%d cells)", vim.fn.fnamemodify(filepath, ":t"), cell_count),
    vim.log.levels.INFO
  )
end

-- Run :checkhealth for this plugin
function M.check()
  local python_path = config.options.python_path or "python3"
  local result = parser.check(python_path)

  if result.ok then
    vim.health.ok("Python bridge OK (Python " .. result.python_version .. ", marimo " .. result.marimo_version .. ")")
  else
    vim.health.error("Python bridge failed: " .. (result.error or "unknown"))
    vim.health.info("Set python_path in setup() to a Python interpreter with marimo installed.")
    vim.health.info("Example: require('neo-marimo').setup({ python_path = '/path/to/venv/bin/python' })")
  end
end

-- Get the notebook state for the current buffer, or nil.
function M.current_notebook()
  local bufname = vim.api.nvim_buf_get_name(0)
  local filepath = bufname:match("^marimo://(.+)$")
  if filepath then
    return _attached[filepath]
  end
  return nil
end

return M

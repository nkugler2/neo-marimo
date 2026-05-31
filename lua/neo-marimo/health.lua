local M = {}

function M.check()
  vim.health.start("neo-marimo")

  local config = require("neo-marimo.config")
  local parser = require("neo-marimo.parser")

  local python_path = config.options.python_path or "python3"
  vim.health.info("python_path: " .. python_path)

  -- Check Python bridge
  local result = parser.check(python_path)
  if result.ok then
    vim.health.ok(
      "Python bridge OK (Python " .. result.python_version
      .. ", marimo " .. (result.marimo_version or "?") .. ")"
    )
  else
    vim.health.error(
      "Python bridge FAILED: " .. (result.error or "unknown error")
    )
    vim.health.info(
      "Fix: set python_path in setup() to a Python with marimo installed."
    )
    vim.health.info(
      "Example: require('neo-marimo').setup({ python_path = '/path/to/venv/bin/python' })"
    )
    return
  end

  -- Check marimo CLI
  local marimo_cmd = config.options.marimo_cmd or "marimo"
  local cli_result = vim.system({ marimo_cmd, "--version" }, { text = true }):wait()
  if cli_result.code == 0 then
    vim.health.ok("marimo CLI found: " .. (cli_result.stdout or ""):gsub("\n", ""))
  else
    vim.health.warn(
      "marimo CLI '" .. marimo_cmd .. "' not found in PATH. "
      .. "':MarimoOpen' and '<leader>mo' won't work. "
      .. "Set marimo_cmd in setup() to the full path."
    )
  end

  -- Check TreeSitter
  local ts_ok, _ = pcall(require, "nvim-treesitter")
  if ts_ok then
    local py_ok = pcall(function()
      vim.treesitter.get_parser(0, "python")
    end)
    if py_ok then
      vim.health.ok("nvim-treesitter with Python parser available (syntax injection will work)")
    else
      vim.health.warn("nvim-treesitter Python parser not installed. Run :TSInstall python")
    end
  else
    vim.health.warn(
      "nvim-treesitter not found. Syntax injection (markdown/SQL in cells) requires "
      .. "nvim-treesitter with python, markdown, and sql parsers."
    )
  end
end

return M

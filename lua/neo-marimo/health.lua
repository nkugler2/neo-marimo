local M = {}

-- marimo minor series the rendering pipeline has been fixture-tested
-- against. Each entry corresponds to a committed corpus under
-- tests/fixtures/<series>/ (captured with tests/capture_fixtures.py and
-- asserted by `make test`). A different series may emit HTML shapes the
-- tree renderer has never seen — usually it still works, but re-capture
-- the fixtures and run the suite before trusting it.
local TESTED_MARIMO_SERIES = { ["0.19"] = true }

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

    -- Compare the probed marimo version against the fixture-tested range.
    local series = (result.marimo_version or ""):match("^(%d+%.%d+)")
    if series and TESTED_MARIMO_SERIES[series] then
      vim.health.ok(
        "marimo " .. result.marimo_version .. " is within the tested range"
        .. " (rendering fixtures: tests/fixtures/" .. series .. "/)"
      )
    elseif series then
      vim.health.warn(
        "marimo " .. result.marimo_version .. " has not been fixture-tested"
        .. " (tested series: " .. table.concat(vim.tbl_keys(TESTED_MARIMO_SERIES), ", ") .. ")."
        .. " Output rendering may mis-parse HTML shapes that changed between versions."
      )
      vim.health.info(
        "To validate: run `make fixtures` with this marimo to re-capture"
        .. " tests/fixtures/, then `make test`."
      )
    end
  elseif result.python_version then
    -- Bridge ran but marimo wasn't importable
    vim.health.error(
      "marimo not found in this Python (Python " .. result.python_version .. "): "
      .. (result.error or "marimo not importable")
    )
    vim.health.info("python_path is: " .. python_path)
    vim.health.info(
      "Fix: set python_path in setup() to the Python that has marimo installed."
    )
    vim.health.info(
      "  Example: require('neo-marimo').setup({ python_path = '/Users/noahkugler/.pyenv/versions/MyMainTestingPython/bin/python' })"
    )
    return
  else
    -- Bridge itself failed to run
    vim.health.error(
      "Python bridge failed to run: " .. (result.error or "could not execute python")
    )
    vim.health.info("python_path is: " .. python_path)
    vim.health.info(
      "Make sure '" .. python_path .. "' is a valid Python 3 interpreter."
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

  -- Check inline-image backend
  local backend = require("neo-marimo.image").backend()
  if backend then
    vim.health.ok("inline-image backend: " .. backend)
    vim.health.info(
      "Inline images also need a graphics-capable terminal (kitty, ghostty, wezterm)."
    )
  else
    vim.health.warn(
      "No inline-image backend found. Plots and images will render as "
      .. "file-path placeholders instead of inline graphics."
    )
    vim.health.info(
      "Install image.nvim, or snacks.nvim with its image feature enabled, "
      .. "and use a graphics-capable terminal (kitty, ghostty, wezterm)."
    )
  end
end

return M

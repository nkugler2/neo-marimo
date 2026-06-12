local M = {}
local utils = require("neo-marimo.utils")

local bridge_path = utils.plugin_root() .. "/python/bridge.py"

-- Parse a marimo notebook file. Returns a table with:
--   cells: list of {name, code, options}
--   version: marimo version string
--   app_options: app constructor kwargs
--   valid: boolean
-- Raises an error string on failure.
-- Bridge calls run on attach/save paths where the result gates the next
-- step, so they stay synchronous — but bounded, so a wedged interpreter
-- (bad python_path, hung import) can't freeze the editor forever.
local BRIDGE_TIMEOUT_MS = 15000

function M.parse_file(filepath, python_path)
  python_path = python_path or "python3"
  local result = vim.system(
    { python_path, bridge_path, "parse", filepath },
    { text = true, timeout = BRIDGE_TIMEOUT_MS }
  ):wait()

  if result.code ~= 0 then
    error("neo-marimo bridge error: " .. (result.stderr or "unknown error"))
  end

  local data, err = utils.json_decode(result.stdout)
  if err then
    error("neo-marimo: failed to parse bridge output: " .. err)
  end

  return data
end

-- Generate a marimo .py file from a list of cells.
-- `cells` is a list of {name, code, options} tables.
-- Returns the generated Python source as a string.
function M.generate_py(cells, filepath, python_path)
  python_path = python_path or "python3"
  local input, err = utils.json_encode({ cells = cells, filepath = filepath })
  if err then
    error("neo-marimo: failed to encode cells: " .. err)
  end

  local result = vim.system(
    { python_path, bridge_path, "generate" },
    { text = true, stdin = input, timeout = BRIDGE_TIMEOUT_MS }
  ):wait()

  if result.code ~= 0 then
    error("neo-marimo bridge error: " .. (result.stderr or "unknown error"))
  end

  return result.stdout
end

-- Run a health check on the Python bridge.
-- Returns {ok, python_version, marimo_version} or raises an error.
function M.check(python_path)
  python_path = python_path or "python3"
  local result = vim.system(
    { python_path, bridge_path, "check" },
    { text = true, timeout = BRIDGE_TIMEOUT_MS }
  ):wait()

  if result.code ~= 0 then
    return { ok = false, error = result.stderr or "bridge failed to run" }
  end

  local data, err = utils.json_decode(result.stdout)
  if err then
    return { ok = false, error = "could not parse bridge output: " .. err }
  end

  return data
end

return M

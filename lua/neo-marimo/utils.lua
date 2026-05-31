local M = {}

-- Debounce: returns a function that delays execution by `ms` milliseconds.
-- Cancels any pending call when invoked again before the timer fires.
function M.debounce(fn, ms)
  local timer = vim.uv.new_timer()
  return function(...)
    local args = { ... }
    timer:stop()
    timer:start(ms, 0, vim.schedule_wrap(function()
      fn(unpack(args))
    end))
  end
end

-- Generate a 4-character cell ID compatible with marimo's CellId_t format.
-- Marimo uses random 4-letter strings internally.
function M.generate_cell_id()
  local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
  local id = ""
  for _ = 1, 4 do
    local idx = math.random(1, #chars)
    id = id .. chars:sub(idx, idx)
  end
  return id
end

-- Safe JSON encode with error handling
function M.json_encode(t)
  local ok, result = pcall(vim.json.encode, t)
  if not ok then
    return nil, result
  end
  return result, nil
end

-- Safe JSON decode with error handling
function M.json_decode(s)
  if not s or s == "" then
    return nil, "empty string"
  end
  local ok, result = pcall(vim.json.decode, s)
  if not ok then
    return nil, result
  end
  return result, nil
end

-- Get the root directory of this plugin (two levels up from this file)
function M.plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h")
end

-- Log a warning to :messages
function M.warn(msg)
  vim.notify("[neo-marimo] " .. msg, vim.log.levels.WARN)
end

-- Log an error to :messages
function M.error(msg)
  vim.notify("[neo-marimo] " .. msg, vim.log.levels.ERROR)
end

-- Log info (only when debug mode is enabled)
function M.info(msg)
  vim.notify("[neo-marimo] " .. msg, vim.log.levels.INFO)
end

return M

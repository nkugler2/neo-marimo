-- Diagnostic logging shared across modules.
--
-- Off unless WS debug logging is enabled (:MarimoWsDebug, which sets
-- _G.neo_marimo_ws_log to a file path). The raw per-message dump in
-- init.lua and the structured re-key / cell-op traces added by output.lua
-- and ws_handlers.lua all funnel through here, so a single :MarimoWsDebug
-- captures the full picture — incoming ops, re-key branch decisions, and
-- dropped cell-ops — in arrival order, in one file.
--
-- Every write is best-effort and fully pcall-guarded: a full disk or an
-- unwritable path can never propagate an error into a WS callback or a
-- render path.

local M = {}

function M.enabled()
  return _G.neo_marimo_ws_log ~= nil
end

-- Append one line: "[HH:MM:SS] <tag> <json|string>". `data` is encoded as
-- compact JSON unless it is already a string. No-op when logging is off.
function M.write(tag, data)
  local path = _G.neo_marimo_ws_log
  if not path then return end
  pcall(function()
    local payload = (type(data) == "string") and data or vim.json.encode(data)
    local f = io.open(path, "a")
    if not f then return end
    f:write(os.date("[%H:%M:%S] ") .. tostring(tag) .. " " .. payload .. "\n")
    f:close()
  end)
end

-- Collect the current cell ids of a notebook in buffer order — the input
-- and result of every re-key, so a trace shows exactly how the mapping moved.
function M.cell_ids(nb)
  local ids = {}
  if nb and nb.cells then
    for _, c in ipairs(nb.cells) do
      ids[#ids + 1] = c.id
    end
  end
  return ids
end

return M

-- WebSocket message dispatch table.
--
-- Built-in handlers (registered at module load) cover marimo's core ops
-- plus the neo_marimo_* status messages emitted by python/ws_client.py.
-- Later phases register additional ops without touching this file:
--   Phase 6 → "update-cell-codes", "completed-run"
--   Phase 7 → "completion-result", "hover-result"
--
-- A handler receives (payload, ctx) where:
--   payload  = the message's `data` field if present, otherwise the whole msg
--   ctx      = { nb = <notebook>, bufnr = <notebook buffer> }

local output = require("neo-marimo.output")
local utils = require("neo-marimo.utils")

local M = {}

M.handlers = {}

-- Register a handler for an op name. Overwrites any previous registration.
function M.register(op, fn)
  M.handlers[op] = fn
end

-- Dispatch a message. Returns true if a handler ran, false otherwise.
function M.dispatch(op, payload, ctx)
  local fn = M.handlers[op]
  if not fn then return false end
  fn(payload, ctx)
  return true
end

-- ── Built-in handlers ──────────────────────────────────────────────────────

M.register("cell-op", function(payload, ctx)
  if ctx.bufnr and vim.api.nvim_buf_is_valid(ctx.bufnr) then
    output.handle_cell_op(ctx.bufnr, ctx.nb, payload)
  end
end)

M.register("kernel-ready", function(payload, ctx)
  -- Server sent kernel-ready: update our cell ID mapping from the server's
  -- authoritative order. The bridge mints local IDs at parse time, but marimo
  -- replaces them on connection — we re-key cells so subsequent cell-op
  -- messages find their target.
  if not payload.cell_ids then return end
  local nb = ctx.nb
  for i, srv_id in ipairs(payload.cell_ids) do
    local cell = nb.cells[i]
    if cell and srv_id ~= cell.id then
      nb.cell_by_id[cell.id] = nil
      cell.id = srv_id
      nb.cell_by_id[srv_id] = cell
    end
  end
end)

M.register("neo_marimo_connected", function(_, _)
  vim.notify("[neo-marimo] WebSocket connected.", vim.log.levels.INFO)
end)

M.register("neo_marimo_error", function(_, ctx)
  utils.warn("WebSocket error: " .. (ctx.raw and ctx.raw.message or "unknown"))
end)

return M

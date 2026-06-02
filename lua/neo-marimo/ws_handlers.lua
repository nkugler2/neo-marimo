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

-- ── Phase 6: bidirectional sync ────────────────────────────────────────────

-- update-cell-codes: sent by marimo when another client (typically the
-- browser) edited cells, or when marimo's --watch picks up a change.
-- Payload is { cell_ids = [...], codes = [...], code_is_stale = bool }.
-- We map codes onto the existing cell list by position and call
-- apply_remote_changes for a minimal-disturbance patch.
--
-- Important: marimo broadcasts this to *every* consumer, including
-- the one whose write triggered it. If the user typed more characters
-- between :w and the WS echo, those characters would be clobbered by
-- the older saved version coming back. sync.is_writing(nb) is true
-- for ~1.5s after our own write; skip in that window. The
-- file-watcher path uses the same suppression.
M.register("update-cell-codes", function(payload, ctx)
  if not ctx.nb or not ctx.bufnr then return end
  local sync = require("neo-marimo.sync")
  if sync.is_writing(ctx.nb) then return end
  local codes = payload.codes
  if type(codes) ~= "table" then return end
  if #codes ~= #ctx.nb.cells then
    -- Cell count mismatch — the WS payload doesn't carry names/options,
    -- so we can't safely synthesize new cells. Defer to the file
    -- watcher (which has the full parse).
    return
  end
  local new_cells = {}
  for i, code in ipairs(codes) do
    table.insert(new_cells, {
      code = code,
      name = ctx.nb.cells[i].name,
      options = ctx.nb.cells[i].options,
    })
  end
  sync.apply_remote_changes(ctx.nb, new_cells)
end)

-- completed-run: empty payload. Marimo sends this after every submitted
-- batch finishes. cell-op already drives the per-cell status indicator,
-- so this is a no-op slot for now — Phase 8 might use it to drive a
-- "notebook idle" indicator in the statusline.
M.register("completed-run", function(_, _) end)

return M

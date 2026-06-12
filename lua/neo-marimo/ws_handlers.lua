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

-- Per-op error counts for the containment below. Exposed for tests and
-- :MarimoWsDebug-style introspection.
M._handler_errors = {}

-- Dispatch a message. Returns true if a handler ran without error, false
-- otherwise.
--
-- Handlers are isolated with pcall: marimo streams dozens of messages per
-- run, and an uncaught error on a payload shape we didn't anticipate would
-- otherwise repeat for every subsequent message — an error loop that makes
-- the whole session unusable. Instead we warn once per op (with the error)
-- and stay silent after that; the count is kept so the problem is still
-- diagnosable.
function M.dispatch(op, payload, ctx)
  local fn = M.handlers[op]
  if not fn then return false end
  local ok, err = pcall(fn, payload, ctx)
  if not ok then
    M._handler_errors[op] = (M._handler_errors[op] or 0) + 1
    if M._handler_errors[op] == 1 then
      utils.warn(
        "WS handler for '" .. tostring(op) .. "' failed: " .. tostring(err)
          .. "\nFurther failures for this op will be suppressed."
      )
    end
    return false
  end
  return true
end

-- ── Built-in handlers ──────────────────────────────────────────────────────

M.register("cell-op", function(payload, ctx)
  if ctx.bufnr and vim.api.nvim_buf_is_valid(ctx.bufnr) then
    output.handle_cell_op(ctx.bufnr, ctx.nb, payload)
  end
end)

-- Walk the cells by position and re-key them to whatever cell_ids the
-- server is announcing. Used by both kernel-ready (initial sync) and
-- update-cell-ids (every reload). When the cell counts mismatch we
-- bail — that means the file has structurally diverged and the
-- file-watcher path will fix things up via apply_remote_changes.
local function rekey_cells_from_server(nb, cell_ids)
  if type(cell_ids) ~= "table" then return end
  if #cell_ids ~= #nb.cells then return end
  for i, srv_id in ipairs(cell_ids) do
    local cell = nb.cells[i]
    if cell and srv_id ~= cell.id then
      nb.cell_by_id[cell.id] = nil
      cell.id = srv_id
      nb.cell_by_id[srv_id] = cell
    end
  end
end

M.register("kernel-ready", function(payload, ctx)
  -- Server sent kernel-ready: update our cell ID mapping from the server's
  -- authoritative order. The bridge mints local IDs at parse time, but marimo
  -- replaces them on connection — we re-key cells so subsequent cell-op
  -- messages find their target.
  if not payload.cell_ids then return end
  rekey_cells_from_server(ctx.nb, payload.cell_ids)
end)

-- update-cell-ids: marimo broadcasts the authoritative cell_id list
-- after every reload (file watcher, save endpoint, etc). New cells we
-- added in nvim got our locally-generated IDs; this is where marimo's
-- replacement IDs land. Without this handler we keep using stale IDs
-- and /api/kernel/run silently registers our IDs as a *second* set of
-- cells in marimo, which is why the browser would show added cells
-- but not the run output: the browser only attaches cell-op to cells
-- it knows about, and our shadow-registered cells aren't in its view.
M.register("update-cell-ids", function(payload, ctx)
  if not ctx.nb then return end
  rekey_cells_from_server(ctx.nb, payload.cell_ids)
  -- Stamp the moment marimo's reload broadcast reached us. The run
  -- path waits for this stamp to overtake nb._last_save_at so it
  -- never POSTs /api/kernel/run with cell IDs that are about to be
  -- replaced — see actions.flush_pending_edits.
  ctx.nb._last_cell_ids_at = (vim.uv.hrtime() / 1e6)
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

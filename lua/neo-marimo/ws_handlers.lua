-- WebSocket message dispatch table.
--
-- Built-in handlers (registered at module load) cover marimo's core ops
-- plus the neo_marimo_* status messages emitted by python/ws_client.py.
-- Later phases register additional ops without touching this file:
--   Phase 6 → "update-cell-codes", "completed-run"
--   Phase 7 → "completion-result", "hover-result"
--
-- Version note: marimo ≤0.19 broadcasts the granular "update-cell-codes" /
-- "update-cell-ids" ops on every reload; 0.23+ dropped both and sends a
-- single payload-less "reload" op instead. We register handlers for all
-- three so the plugin works across both series.
--
-- A handler receives (payload, ctx) where:
--   payload  = the message's `data` field if present, otherwise the whole msg
--   ctx      = { nb = <notebook>, bufnr = <notebook buffer> }

local output = require("neo-marimo.output")
local utils = require("neo-marimo.utils")
local log = require("neo-marimo.log")
local widgets = require("neo-marimo.widgets")

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

-- Rebuild nb.cell_by_id from the current nb.cells ids. The only
-- collision-safe way to re-key: assigning ids cell-by-cell while also
-- mutating cell_by_id can null an entry we just set when one cell's new id
-- equals another cell's old id (the latent bug in the old positional walk).
local function rebuild_index(nb)
  nb.cell_by_id = {}
  for _, c in ipairs(nb.cells) do nb.cell_by_id[c.id] = c end
end

-- Positional re-key: assign the i-th server id to the i-th nvim cell, then
-- rebuild the index in one pass. Caller guarantees counts line up.
local function rekey_by_position(nb, cell_ids)
  for i, srv_id in ipairs(cell_ids) do
    if nb.cells[i] then nb.cells[i].id = srv_id end
  end
  rebuild_index(nb)
end

-- Content-based re-key: pair each server (id, code) with the nvim cell that
-- has identical code, consuming each nvim cell at most once so two cells
-- with the same source (e.g. duplicate mo.ui.slider cells) still map 1:1 in
-- order. Returns true only if every server id found a distinct match — the
-- caller falls back to positional/reload re-keying when it returns false.
local function rekey_by_code(nb, cell_ids, codes)
  if type(codes) ~= "table" or #cell_ids ~= #codes then return false end
  local used, assign = {}, {}
  for i, srv_id in ipairs(cell_ids) do
    local want, match = codes[i], nil
    for j, cell in ipairs(nb.cells) do
      if not used[j] and (cell.code or "") == want then
        match, used[j] = cell, true
        break
      end
    end
    if not match then return false end
    assign[match] = srv_id
  end
  for cell, srv_id in pairs(assign) do cell.id = srv_id end
  rebuild_index(nb)
  return true
end

-- Re-key nb.cells to the server's authoritative cell_ids. Preference order:
--   1. Match by code when the server sends codes (kernel-ready, update-cell-
--      codes) — robust to reorders and to a count that hasn't reconciled yet.
--   2. Positional re-key when counts already line up.
--   3. Ids-only with a count mismatch → rebuild nb.cells from disk (the same
--      file marimo just parsed, so order/count align by construction) and
--      then re-key positionally. This replaces the old "bail on mismatch",
--      which left stale ids so the cell's later cell-ops landed on an unknown
--      id and were dropped — the root of the cell-id desync bug.
--
-- Returns true iff nb.cell_by_id was actually reconciled to the server's
-- ids, false when it bailed (still-writing skip, or a failed reload+count
-- mismatch). Callers that gate on "ids are now safe to run against" (see
-- update-cell-ids below) must check this — stamping unconditionally is the
-- root of the "queued forever" bug: a bailed re-key leaves stale local ids,
-- a run POSTs under them, and the eventual real re-key drops the mapping so
-- the terminal cell-op lands on an unknown id and the queued status never
-- clears.
local function rekey_cells_from_server(nb, cell_ids, codes)
  if type(cell_ids) ~= "table" then return false end
  if log.enabled() then
    log.write("rekey:in", {
      server_ids = cell_ids,
      server_count = #cell_ids,
      has_codes = type(codes) == "table",
      nb_count = #nb.cells,
      nb_ids = log.cell_ids(nb),
    })
  end
  if codes and rekey_by_code(nb, cell_ids, codes) then
    if log.enabled() then log.write("rekey:done", { via = "code", nb_ids = log.cell_ids(nb) }) end
    return true
  end
  if #cell_ids == #nb.cells then
    rekey_by_position(nb, cell_ids)
    if log.enabled() then log.write("rekey:done", { via = "position", nb_ids = log.cell_ids(nb) }) end
    return true
  end
  -- Ids-only with a count mismatch. Don't clobber unsaved edits mid-write;
  -- the paired update-cell-codes (or a later broadcast) reconciles by code.
  local sync = require("neo-marimo.sync")
  if sync.is_writing(nb) then
    if log.enabled() then log.write("rekey:skip", { reason = "writing" }) end
    return false
  end
  if sync.reload_from_file(nb) and #cell_ids == #nb.cells then
    rekey_by_position(nb, cell_ids)
    if log.enabled() then log.write("rekey:done", { via = "reload+position", nb_ids = log.cell_ids(nb) }) end
    return true
  elseif log.enabled() then
    log.write("rekey:fail", {
      reason = "count_mismatch", server_count = #cell_ids, nb_count = #nb.cells,
    })
  end
  return false
end

M.register("kernel-ready", function(payload, ctx)
  -- Server sent kernel-ready: update our cell ID mapping from the server's
  -- authoritative order. The bridge mints local IDs at parse time, but marimo
  -- replaces them on connection — we re-key cells so subsequent cell-op
  -- messages find their target.
  if not payload.cell_ids then return end
  -- kernel-ready carries codes alongside cell_ids; matching by code re-keys
  -- correctly even after the local order has drifted from the server's.
  rekey_cells_from_server(ctx.nb, payload.cell_ids, payload.codes)
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
  local reconciled = rekey_cells_from_server(ctx.nb, payload.cell_ids)
  -- Stamp the moment marimo's reload broadcast reached us — but only if
  -- the re-key actually landed. actions.flush_pending_edits treats this
  -- stamp as "ids are safe to run against"; a bailed re-key (mismatch
  -- while writing, or a failed reload) leaves nb.cells keyed by stale
  -- local ids, so stamping unconditionally let a run POST under an id
  -- that a later, real re-key would drop — the terminal cell-op then
  -- arrives under an unknown id and the optimistic "queued" status never
  -- clears. See docs/plan-refinement.md F1.2.
  if reconciled then
    ctx.nb._last_cell_ids_at = (vim.uv.hrtime() / 1e6)
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
  -- Re-key before patching code. A reload that changed cell ids broadcasts
  -- update-cell-ids (ids only) and update-cell-codes (ids + codes) together;
  -- if the ids-only handler had to bail, matching by code here recovers the
  -- mapping so later cell-ops don't land on unknown ids. By this point the
  -- run path has already written our edits, so nb.cells holds these codes.
  if payload.cell_ids then
    rekey_cells_from_server(ctx.nb, payload.cell_ids, codes)
  end
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

-- reload: marimo 0.23+ replaced the granular update-cell-codes /
-- update-cell-ids broadcasts with a single payload-less "reload" op,
-- emitted by --watch's file-change handler (and after a save). It carries
-- no cell_ids or codes — the frontend is expected to re-fetch state — so we
-- do the two things the old handlers did for us:
--   1. Stamp _last_cell_ids_at. actions.flush_pending_edits blocks up to
--      1.5s waiting for this stamp to overtake _last_save_at; on 0.23 no
--      update-cell-ids arrives, so without this every run eats the full
--      timeout. 0.23 is client-ID-authoritative (/api/kernel/run registers
--      unseen IDs), so the IDs we already hold stay valid — only the
--      unblock matters.
--   2. Re-sync from disk for external/browser/--watch edits. Skip inside
--      our own write-suppression window (a save we just made) so we don't
--      clobber characters the user typed between :w and the echo — same
--      guard the old update-cell-codes handler used.
M.register("reload", function(_, ctx)
  if not ctx.nb then return end
  ctx.nb._last_cell_ids_at = (vim.uv.hrtime() / 1e6)
  local sync = require("neo-marimo.sync")
  if not sync.is_writing(ctx.nb) then
    sync.reload_from_file(ctx.nb)
  end
end)

-- completed-run: empty payload. Marimo sends this after every submitted
-- batch finishes. cell-op already drives the per-cell status indicator,
-- so this is a no-op slot for now — Phase 8 might use it to drive a
-- "notebook idle" indicator in the statusline.
M.register("completed-run", function(_, _) end)

-- ── widget value sync (browser/other-consumer → nvim) ───────────────────────
--
-- When any consumer changes a UI element's value, marimo recomputes the
-- dependent cells (those cell-ops arrive and render fine) but NEVER
-- re-broadcasts the widget's own cell — so without the two handlers below
-- nvim's slider/checkbox stays where it was even though the value changed.
-- The signal that carries the new value is the "variable-values" op; to map a
-- variable back to its widget we first need "variables", which says which cell
-- declares each variable (a widget's object-id is "<declaring-cell>-<n>").
--
-- The reverse (nvim → browser) is NOT fixable here: the browser only gets the
-- same variable-values broadcast and marimo's frontend doesn't reposition
-- another session's widget from it either. The value and all downstream cells
-- still sync both ways; only the *other* editor's widget glyph stays put.

-- Coerce a variable-values entry to a display value, or nil to skip it (a null
-- value, or a non-scalar datatype like a range slider's tuple that we can't
-- represent as a single override without risking a wrong/garbled display).
local function coerce_var_value(v)
  if type(v) ~= "table" or v.value == nil then return nil end
  local val, dt = v.value, v.datatype
  if dt == "int" or dt == "float" or dt == "number" then
    return tonumber(val)
  elseif dt == "bool" or dt == "boolean" then
    return (val == true or val == "True" or val == "true")
  elseif dt == "str" or dt == "string" or dt == "text" then
    return tostring(val)
  end
  return nil
end

-- variables: marimo's variable dependency graph, broadcast once per run and on
-- (re)connect. Keep name → declaring cell so a later variable-values update
-- can find the widget that variable produced.
M.register("variables", function(payload, ctx)
  local nb = ctx.nb
  if not nb or type(payload.variables) ~= "table" then return end
  nb._var_decl = nb._var_decl or {}
  for _, v in ipairs(payload.variables) do
    if type(v) == "table" and v.name and type(v.declared_by) == "table" then
      nb._var_decl[v.name] = v.declared_by[1]
    end
  end
end)

-- variable-values: a variable's runtime value (re)computed. For variables that
-- back a UI element, stash the new value as an override and re-render the cell
-- so the widget glyph moves to match. Skips when the declaring cell produced
-- more than one widget (ambiguous which variable maps to which object-id).
M.register("variable-values", function(payload, ctx)
  local nb, bufnr = ctx.nb, ctx.bufnr
  if not nb or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if type(payload.variables) ~= "table" then return end
  local decl = nb._var_decl or {}
  local dirty = {}
  for _, v in ipairs(payload.variables) do
    local coerced = coerce_var_value(v)
    local cell_id = v.name and decl[v.name]
    if coerced ~= nil and cell_id then
      local hits = widgets.find_by_object_prefix(bufnr, cell_id .. "-")
      if #hits == 1 then
        widgets.set_override(hits[1].widget.object_id, coerced)
        dirty[hits[1].cell_id] = true
      end
    end
  end
  for cid in pairs(dirty) do
    local cell = nb.cell_by_id and nb.cell_by_id[cid]
    if cell then output.render(bufnr, cell, nb.filepath) end
  end
end)

return M

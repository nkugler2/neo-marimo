-- WS dispatch error containment: a handler that throws on an unexpected
-- payload must produce exactly one warning and never an error loop —
-- marimo streams dozens of messages per run, so an uncontained error
-- would repeat for every subsequent message.

local t = require("helpers")
local ws = require("neo-marimo.ws_handlers")

t.case("ws: throwing handler is contained and warned once", function()
  local notify_count = 0
  local orig_notify = vim.notify
  vim.notify = function() notify_count = notify_count + 1 end

  ws.register("test-explode", function() error("boom") end)
  local ok1 = ws.dispatch("test-explode", {}, {})
  local ok2 = ws.dispatch("test-explode", {}, {})
  local ok3 = ws.dispatch("test-explode", {}, {})

  vim.notify = orig_notify
  ws.handlers["test-explode"] = nil
  ws._handler_errors["test-explode"] = nil

  t.eq(ok1, false)
  t.eq(ok2, false)
  t.eq(ok3, false)
  t.eq(notify_count, 1, "exactly one warning for repeated handler failures")
end)

t.case("ws: healthy handlers still dispatch normally", function()
  local seen = nil
  ws.register("test-ok", function(payload) seen = payload.value end)
  local ok = ws.dispatch("test-ok", { value = 42 }, {})
  ws.handlers["test-ok"] = nil

  t.eq(ok, true)
  t.eq(seen, 42)
end)

t.case("ws: unknown op returns false without error", function()
  t.eq(ws.dispatch("no-such-op", {}, {}), false)
end)

-- marimo 0.23+ replaced update-cell-ids/update-cell-codes with a single
-- payload-less "reload" op. The handler must unblock the run-gate
-- (_last_cell_ids_at stamp) and re-sync from disk, except inside our own
-- write-suppression window where a resync would clobber un-echoed edits.
t.case("ws: reload stamps _last_cell_ids_at and resyncs when idle", function()
  local sync = require("neo-marimo.sync")
  local orig_is_writing, orig_reload = sync.is_writing, sync.reload_from_file
  local resynced = 0
  sync.is_writing = function() return false end
  sync.reload_from_file = function() resynced = resynced + 1 end

  local nb = { _last_cell_ids_at = 0 }
  local ok = ws.dispatch("reload", {}, { nb = nb })

  sync.is_writing, sync.reload_from_file = orig_is_writing, orig_reload

  t.eq(ok, true)
  t.ok(nb._last_cell_ids_at > 0, "reload stamps _last_cell_ids_at")
  t.eq(resynced, 1, "reload re-syncs from disk when not writing")
end)

t.case("ws: reload skips resync during write-suppression window", function()
  local sync = require("neo-marimo.sync")
  local orig_is_writing, orig_reload = sync.is_writing, sync.reload_from_file
  local resynced = 0
  sync.is_writing = function() return true end
  sync.reload_from_file = function() resynced = resynced + 1 end

  local nb = { _last_cell_ids_at = 0 }
  local ok = ws.dispatch("reload", {}, { nb = nb })

  sync.is_writing, sync.reload_from_file = orig_is_writing, orig_reload

  t.eq(ok, true)
  t.ok(nb._last_cell_ids_at > 0, "reload still stamps _last_cell_ids_at while writing")
  t.eq(resynced, 0, "reload does not clobber the buffer during our own write")
end)

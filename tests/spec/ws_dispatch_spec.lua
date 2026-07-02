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

-- Cell-id desync fix: a reload can hand us the authoritative ids in a
-- different order than our local cells. kernel-ready (and update-cell-codes)
-- carry codes, so we re-key by content instead of by position — the old
-- positional walk mis-mapped exactly the cells the user had edited/split.
t.case("ws: kernel-ready re-keys by code when local order has drifted", function()
  local nb = t.make_notebook({ "a = 1", "b = 2", "c = 3" })
  ws.dispatch("kernel-ready", {
    cell_ids = { "S2", "S1", "S3" },
    codes = { "b = 2", "a = 1", "c = 3" },
  }, { nb = nb })

  t.eq(nb.cell_by_id["S1"].code, "a = 1", "S1 maps to the a=1 cell")
  t.eq(nb.cell_by_id["S2"].code, "b = 2", "S2 maps to the b=2 cell")
  t.eq(nb.cell_by_id["S3"].code, "c = 3", "S3 maps to the c=3 cell")
end)

-- Two cells with identical source (the repro: duplicate mo.ui.slider cells)
-- must still map 1:1 — each nvim cell is consumed at most once.
t.case("ws: kernel-ready maps duplicate-code cells one-to-one", function()
  local nb = t.make_notebook({ "x = slider()", "x = slider()" })
  ws.dispatch("kernel-ready", {
    cell_ids = { "D1", "D2" },
    codes = { "x = slider()", "x = slider()" },
  }, { nb = nb })

  t.ok(nb.cell_by_id["D1"], "D1 mapped to a cell")
  t.ok(nb.cell_by_id["D2"], "D2 mapped to a cell")
  t.ok(nb.cell_by_id["D1"] ~= nb.cell_by_id["D2"], "duplicate-code cells stay distinct")
end)

-- Ids-only broadcast (0.19's update-cell-ids) with a count mismatch used to
-- bail and leave stale ids. Now it rebuilds nb.cells from disk so order/count
-- align, then re-keys — except inside our own write-suppression window.
t.case("ws: update-cell-ids reloads from disk on a count mismatch", function()
  local sync = require("neo-marimo.sync")
  local orig_is_writing, orig_reload = sync.is_writing, sync.reload_from_file
  local reloaded = 0
  sync.is_writing = function() return false end
  sync.reload_from_file = function() reloaded = reloaded + 1; return true end

  local nb = t.make_notebook({ "a = 1", "b = 2" })
  ws.dispatch("update-cell-ids", { cell_ids = { "X1", "X2", "X3" } }, { nb = nb })

  sync.is_writing, sync.reload_from_file = orig_is_writing, orig_reload
  t.eq(reloaded, 1, "count mismatch with no codes triggers reload_from_file")
end)

t.case("ws: update-cell-ids skips the reload during our own write", function()
  local sync = require("neo-marimo.sync")
  local orig_is_writing, orig_reload = sync.is_writing, sync.reload_from_file
  local reloaded = 0
  sync.is_writing = function() return true end
  sync.reload_from_file = function() reloaded = reloaded + 1; return true end

  local nb = t.make_notebook({ "a = 1", "b = 2" })
  ws.dispatch("update-cell-ids", { cell_ids = { "X1", "X2", "X3" } }, { nb = nb })

  sync.is_writing, sync.reload_from_file = orig_is_writing, orig_reload
  t.eq(reloaded, 0, "no reload while writing — would clobber unsaved edits")
end)

-- F1.2 regression: a bailed re-key (count mismatch while sync.is_writing)
-- must NOT stamp _last_cell_ids_at. The stamp is the run-gate's signal that
-- ids are safe to POST against (actions.flush_pending_edits); stamping it
-- unconditionally here — even though nb.cell_by_id was never reconciled —
-- let a run go out under stale local ids, and the eventual real re-key
-- dropped that mapping so the terminal cell-op landed on an unknown id and
-- the optimistic "queued" status never cleared ("queued forever").
t.case("ws: update-cell-ids does not stamp _last_cell_ids_at when the re-key bails", function()
  local sync = require("neo-marimo.sync")
  local orig_is_writing, orig_reload = sync.is_writing, sync.reload_from_file
  sync.is_writing = function() return true end
  sync.reload_from_file = function() error("must not be called while writing") end

  local nb = t.make_notebook({ "a = 1", "b = 2" })
  nb._last_cell_ids_at = 0
  ws.dispatch("update-cell-ids", { cell_ids = { "X1", "X2", "X3" } }, { nb = nb })

  sync.is_writing, sync.reload_from_file = orig_is_writing, orig_reload
  t.eq(nb._last_cell_ids_at, 0, "stamp must not advance when the re-key bailed")
end)

-- Widget value sync (browser/other consumer → nvim): marimo never re-broadcasts
-- the widget's own cell when its value changes, only a "variable-values" op.
-- We map the variable to its widget via the "variables" declaring-cell graph
-- (object-id is "<declaring-cell>-<n>") and stash a value override so the
-- widget glyph re-renders at the new position.
t.case("ws: variable-values moves a widget to the broadcast value", function()
  local widgets = require("neo-marimo.widgets")
  widgets.clear_all_overrides()
  local nb, bufnr = t.make_notebook({ "s = 1", "y = s" })
  local cell = nb.cells[1].id
  local obj = cell .. "-0"
  widgets.register_widget(bufnr, cell, { name = "slider", object_id = obj, value = 1 })

  ws.dispatch("variables",
    { variables = { { name = "s", declared_by = { cell }, used_by = {} } } },
    { nb = nb, bufnr = bufnr })
  ws.dispatch("variable-values",
    { variables = { { name = "s", value = "42", datatype = "int" } } },
    { nb = nb, bufnr = bufnr })

  t.eq(widgets.get_override(obj), 42, "override set to the broadcast value")
  widgets.clear_all_overrides()
end)

t.case("ws: variable-values is ambiguous when a cell has >1 widget — skip", function()
  local widgets = require("neo-marimo.widgets")
  widgets.clear_all_overrides()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2" })
  local cell = nb.cells[1].id
  widgets.register_widget(bufnr, cell, { name = "slider", object_id = cell .. "-0", value = 1 })
  widgets.register_widget(bufnr, cell, { name = "slider", object_id = cell .. "-1", value = 2 })

  ws.dispatch("variables",
    { variables = { { name = "a", declared_by = { cell } } } }, { nb = nb, bufnr = bufnr })
  ws.dispatch("variable-values",
    { variables = { { name = "a", value = "9", datatype = "int" } } }, { nb = nb, bufnr = bufnr })

  t.eq(widgets.get_override(cell .. "-0"), nil, "ambiguous declaring cell → no override")
  t.eq(widgets.get_override(cell .. "-1"), nil)
  widgets.clear_all_overrides()
end)

t.case("ws: variable-values ignores null and non-scalar datatypes", function()
  local widgets = require("neo-marimo.widgets")
  widgets.clear_all_overrides()
  local nb, bufnr = t.make_notebook({ "s = 1" })
  local cell = nb.cells[1].id
  widgets.register_widget(bufnr, cell, { name = "slider", object_id = cell .. "-0", value = 1 })
  ws.dispatch("variables",
    { variables = { { name = "s", declared_by = { cell } } } }, { nb = nb, bufnr = bufnr })

  -- the element object itself (null value at init)
  ws.dispatch("variable-values",
    { variables = { { name = "s", datatype = "slider" } } }, { nb = nb, bufnr = bufnr })
  t.eq(widgets.get_override(cell .. "-0"), nil, "null value ignored")

  -- a range slider tuple — not safely representable as one override
  ws.dispatch("variable-values",
    { variables = { { name = "s", value = "(1, 2)", datatype = "tuple" } } }, { nb = nb, bufnr = bufnr })
  t.eq(widgets.get_override(cell .. "-0"), nil, "non-scalar datatype ignored")
  widgets.clear_all_overrides()
end)

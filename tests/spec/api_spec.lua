-- Phase 12: the public extension API on require("neo-marimo"). Each
-- register_* delegator must actually land in its backing registry and be
-- reachable through the real render/dispatch paths.

local t = require("helpers")
local marimo = require("neo-marimo")
local output = require("neo-marimo.output")
local widgets = require("neo-marimo.widgets")
local ws_handlers = require("neo-marimo.ws_handlers")
local cell_mod = require("neo-marimo.cell")

t.case("api: register_output_renderer routes a custom mimetype", function()
  marimo.register_output_renderer("text/x-spec-test", function(data)
    return { { { "  spec:" .. tostring(data), "MarimoOutputText" } } }
  end)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x = 1" })
  local cell = {
    id = "apicell1", index = 1, name = "_",
    start_row = 0, end_row = 0, status = "idle", _has_run = true,
    output = { mimetype = "text/x-spec-test", data = "hello" },
  }
  output.render(bufnr, cell)

  local hl = require("neo-marimo.highlights")
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns_output, 0, -1, { details = true })
  local joined = ""
  for _, m in ipairs(marks) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      for _, ch in ipairs(vl) do joined = joined .. ch[1] end
      joined = joined .. "\n"
    end
  end
  t.match(joined, "spec:hello", "custom renderer received the payload")
end)

t.case("api: register_widget_renderer routes a custom widget name", function()
  local w = { name = "spec_widget", value = 7, options = {}, label = "gauge" }

  -- Unregistered names fall back to the [name] value=… placeholder.
  local before = widgets.render_widget(w)
  t.match(before[1][2][1], "%[spec_widget%]", "unknown renderer placeholder")

  marimo.register_widget_renderer("spec_widget", function(widget)
    return { { { "  custom:" .. tostring(widget.label), "MarimoWidgetLabel" } } }
  end)
  local lines = widgets.render_widget(w)
  t.eq(lines[1][1][1], "  custom:gauge", "registered renderer wins")

  -- The focus pass swaps the leading chunk for the ▸ marker.
  w.focused = true
  local focused = widgets.render_widget(w)
  t.eq(focused[1][1][1], "▸ ", "focus marker replaces the indent chunk")
end)

t.case("api: a throwing widget renderer gets a placeholder, not an abort (F4.1)", function()
  -- F4.1: widgets.M.render_widget used to call the registered renderer
  -- directly with no pcall — a throw here propagated out through
  -- tree_render's node walk and aborted the whole cell's output build,
  -- taking every sibling widget in the same layout down with it.
  marimo.register_widget_renderer("spec_throws", function()
    error("boom")
  end)

  local lines = widgets.render_widget({ name = "spec_throws", value = 1, options = {} })
  t.ok(lines[1] ~= nil, "a placeholder line is returned instead of raising")
  t.match(lines[1][1][1], "widget error", "placeholder names the failure")

  -- Deregister so other specs see the stock unknown-renderer fallback.
  -- register_renderer(name, nil) is the deregister path (plan-refinement
  -- F4.4) now that widgets' RENDERERS table isn't reachable to splice
  -- directly.
  widgets.register_renderer("spec_throws", nil)

  -- A normal, unrelated widget still renders fine afterwards.
  local ok_lines = widgets.render_widget({ name = "slider", value = 3, options = { start = 0, stop = 10 } })
  t.ok(ok_lines[1] ~= nil, "unrelated widget renders normally after the throw")
  t.no_match(ok_lines[1][1][1] or "", "error", "no error leaked into an unrelated widget")

  -- The deregister actually took effect: spec_throws now falls back to the
  -- unknown-renderer placeholder instead of either the custom handler or the
  -- error placeholder.
  local after = widgets.render_widget({ name = "spec_throws", value = 1, options = {} })
  t.match(after[1][2][1], "%[spec_throws%]", "unknown renderer placeholder after deregister")
end)

t.case("api: register_ws_handler dispatches the op", function()
  local got = nil
  marimo.register_ws_handler("x-spec-op", function(payload, ctx)
    got = { payload = payload, ctx = ctx }
  end)
  local handled = ws_handlers.dispatch("x-spec-op", { a = 1 }, { nb = "NB" })
  t.ok(handled, "dispatch returns true for a registered op")
  t.eq(got.payload.a, 1)
  t.eq(got.ctx.nb, "NB")

  -- register(op, nil) is the deregister path (plan-refinement F4.4) now that
  -- ws_handlers' handlers table isn't reachable to splice directly.
  ws_handlers.register("x-spec-op", nil)
  t.eq(ws_handlers.dispatch("x-spec-op", { a = 1 }, { nb = "NB" }), false,
    "dispatch returns false once the op is deregistered")
end)

t.case("api: register_cell_detector participates in detect_type", function()
  marimo.register_cell_detector("spectype", function(code)
    return code:find("SPECMARKER", 1, true) ~= nil
  end, 5)
  t.eq(cell_mod.detect_type("x = 1  # SPECMARKER"), "spectype")
  t.eq(cell_mod.detect_type("x = 1"), "python")
  -- Remove the detector so other specs see the stock chain. A nil predicate
  -- is the deregister path (plan-refinement F4.4) now that the detector
  -- chain isn't reachable to splice directly.
  cell_mod.register_detector("spectype", nil)
  t.eq(cell_mod.detect_type("x = 1  # SPECMARKER"), "python",
    "deregistered detector no longer matches")
end)

t.case("api: a throwing detector is skipped, not fatal — cell.new still succeeds (F4.1)", function()
  -- F4.1: M.detect_type used to call each predicate with no pcall, so a
  -- throwing detector raised straight out of cell.new during parse and
  -- broke attach entirely. It should now be skipped (falling through to
  -- the remaining detectors / the python default) instead of aborting.
  marimo.register_cell_detector("spec_throws", function()
    error("boom")
  end, 1)

  local ok, detected = pcall(cell_mod.detect_type, "x = 1")
  t.ok(ok, "detect_type does not raise when a detector throws")
  t.eq(detected, "python", "falls through to the default")

  local ok_new, cell = pcall(cell_mod.new, { code = "x = 1" }, 1)
  t.ok(ok_new, "cell.new does not raise when a detector throws")
  t.eq(cell.type, "python", "cell still constructed with the fallback type")

  -- Our throwing detector sits at priority 1, ahead of the built-in
  -- markdown detector (priority 10) — so a markdown-matching cell still
  -- reaches and matches it, proving detection falls through past the
  -- throw to the rest of the chain rather than stopping there.
  t.eq(cell_mod.detect_type("mo.md('hi')"), "markdown",
    "later detectors in the chain still run after an earlier one throws")

  cell_mod.register_detector("spec_throws", nil)
  local ok_after, detected_after = pcall(cell_mod.detect_type, "x = 1")
  t.ok(ok_after, "detect_type no longer touches the throwing detector")
  t.eq(detected_after, "python", "falls through to the default after deregister")
end)

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

t.case("api: register_ws_handler dispatches the op", function()
  local got = nil
  marimo.register_ws_handler("x-spec-op", function(payload, ctx)
    got = { payload = payload, ctx = ctx }
  end)
  local handled = ws_handlers.dispatch("x-spec-op", { a = 1 }, { nb = "NB" })
  t.ok(handled, "dispatch returns true for a registered op")
  t.eq(got.payload.a, 1)
  t.eq(got.ctx.nb, "NB")
  ws_handlers.handlers["x-spec-op"] = nil
end)

t.case("api: register_cell_detector participates in detect_type", function()
  marimo.register_cell_detector(function(code)
    return code:find("SPECMARKER", 1, true) ~= nil
  end, "spectype", 5)
  t.eq(cell_mod.detect_type("x = 1  # SPECMARKER"), "spectype")
  t.eq(cell_mod.detect_type("x = 1"), "python")
  -- Remove the detector so other specs see the stock chain.
  for i, d in ipairs(cell_mod.detectors) do
    if d.type == "spectype" then table.remove(cell_mod.detectors, i) break end
  end
end)

-- Phase 10 tests: widget focus model, tab metadata + gutter, picker
-- grouping, pins, and nudge value math. UI windows (picker floats) aren't
-- driven here — everything under them is pure and tested directly.

local t = require("helpers")
local tree_render = require("neo-marimo.tree_render")
local widgets = require("neo-marimo.widgets")
local widget_picker = require("neo-marimo.widget_picker")

local _next = 0

-- Render a fixture against a stable (bufnr, cell_id) so focus state can be
-- exercised across re-renders. Clears the registry first, mirroring what
-- output.M.render does before each real render pass.
local function render_with(name, bufnr, cell_id)
  widgets.clear_for_cell(bufnr, cell_id)
  local ctx = { bufnr = bufnr, cell_id = cell_id, row = 0 }
  local virt = tree_render.render(t.fixture(name), ctx)
  return t.flat_lines(virt), widgets.list_for_cell(bufnr, cell_id)
end

local function fresh_target()
  _next = _next + 1
  return vim.api.nvim_create_buf(false, true), "uxcell" .. _next
end

-- ── focus model ───────────────────────────────────────────────────────────

t.case("focus: marker renders on the focused widget only", function()
  local bufnr, cell_id = fresh_target()
  local lines, reg = render_with("vstack_widgets", bufnr, cell_id)
  t.no_match(table.concat(lines, "\n"), "▸", "no marker before focus")
  t.eq(#reg, 3)

  widgets.set_focus(bufnr, cell_id, reg[2].object_id, 2)
  local lines2 = render_with("vstack_widgets", bufnr, cell_id)
  local marked = {}
  for _, l in ipairs(lines2) do
    if l:find("▸") then table.insert(marked, l) end
  end
  t.eq(#marked, 1, "exactly one line carries the marker")
  t.match(marked[1], "Check", "marker is on the focused checkbox")

  widgets.clear_focus(bufnr)
  local lines3 = render_with("vstack_widgets", bufnr, cell_id)
  t.no_match(table.concat(lines3, "\n"), "▸", "marker gone after clear")
end)

t.case("focus: object-id match wins, index is the fallback", function()
  local bufnr, cell_id = fresh_target()
  local _, reg = render_with("vstack_widgets", bufnr, cell_id)

  -- object_id set: matches its widget even at the "wrong" index.
  widgets.set_focus(bufnr, cell_id, reg[3].object_id, 1)
  t.ok(widgets.is_focused(bufnr, cell_id, reg[3], 3), "id match")
  t.ok(not widgets.is_focused(bufnr, cell_id, reg[1], 1), "index ignored when ids known")

  -- no object_id on the focus entry: index decides.
  widgets.set_focus(bufnr, cell_id, nil, 2)
  t.ok(widgets.is_focused(bufnr, cell_id, reg[2], 2), "index fallback")
  t.ok(not widgets.is_focused(bufnr, cell_id, reg[1], 1))

  widgets.clear_focus(bufnr)
end)

t.case("focus: focused_widget resolves against the live registry", function()
  local bufnr, cell_id = fresh_target()
  local _, reg = render_with("vstack_widgets", bufnr, cell_id)

  t.eq(widgets.focused_widget(bufnr), nil, "nothing focused yet")

  widgets.set_focus(bufnr, cell_id, reg[1].object_id, 1)
  local w, cid = widgets.focused_widget(bufnr)
  t.eq(w.object_id, reg[1].object_id)
  t.eq(cid, cell_id)

  -- Cell output stops containing widgets → focus resolves to nil.
  widgets.clear_for_cell(bufnr, cell_id)
  t.eq(widgets.focused_widget(bufnr), nil, "stale focus resolves to nil")
  widgets.clear_focus(bufnr)
end)

-- ── tab metadata + gutter ─────────────────────────────────────────────────

t.case("tabs: widgets carry their tab, indexes stamped in order", function()
  local bufnr, cell_id = fresh_target()
  local _, reg = render_with("tabs_with_table", bufnr, cell_id)
  t.eq(#reg, 3)
  t.eq(reg[1].index, 1)
  t.eq(reg[3].index, 3)
  t.eq(reg[1].tab.label, "Selectors")
  t.eq(reg[2].tab.label, "Selectors")
  t.ok(reg[1].tab == reg[2].tab, "same body shares one tab table")
  t.eq(reg[3].tab.label, "Refresh")
  t.ok(reg[1].tab ~= reg[3].tab, "different bodies get distinct tab tables")

  -- Widgets outside tabs have no tab.
  local _, flat_reg = render_with("vstack_widgets", bufnr, cell_id .. "b")
  t.eq(flat_reg[1].tab, nil)
end)

t.case("tabs: body lines get the │ gutter, headers don't", function()
  local bufnr, cell_id = fresh_target()
  local lines = render_with("tabs_simple", bufnr, cell_id)
  local in_body = false
  for _, l in ipairs(lines) do
    if l:find("▎ tab: ") then
      t.no_match(l, "│", "header has no gutter")
      in_body = true
    elseif in_body and l:match("%S") then
      t.match(l, "^  │", "body line is gutter-prefixed: " .. l)
    end
  end
end)

-- ── picker grouping ───────────────────────────────────────────────────────

t.case("picker: groups follow tab bodies in document order", function()
  local bufnr, cell_id = fresh_target()
  local _, reg = render_with("tabs_with_table", bufnr, cell_id)
  local groups = widget_picker._group_by_tab(reg)
  t.eq(#groups, 2)
  t.eq(groups[1].label, "Selectors")
  t.eq(#groups[1].items, 2)
  t.eq(groups[2].label, "Refresh")
  t.eq(#groups[2].items, 1)
end)

t.case("picker: tabless widgets form a single unlabeled group", function()
  local bufnr, cell_id = fresh_target()
  local _, reg = render_with("vstack_widgets", bufnr, cell_id)
  local groups = widget_picker._group_by_tab(reg)
  t.eq(#groups, 1)
  t.eq(groups[1].label, nil)
  t.eq(#groups[1].items, 3)
end)

-- ── pins ──────────────────────────────────────────────────────────────────

t.case("pins: toggle, list, unpin lifecycle", function()
  local fp = "/tmp/fake-notebook-" .. _next .. ".py"
  local w1 = { name = "slider", object_id = "p1", label = "speed" }
  local w2 = { name = "checkbox", object_id = "p2", label = "flag" }

  t.eq(#widgets.pins_for(fp), 0)
  t.eq(widgets.toggle_pin(fp, "cellA", w1), true, "pinned")
  t.eq(widgets.toggle_pin(fp, "cellB", w2), true)
  t.ok(widgets.is_pinned(fp, "p1"))
  t.eq(#widgets.pins_for(fp), 2)
  t.eq(widgets.pins_for(fp)[1].label, "speed")
  t.eq(widgets.pins_for(fp)[1].cell_id, "cellA")

  t.eq(widgets.toggle_pin(fp, "cellA", w1), false, "second toggle unpins")
  t.eq(#widgets.pins_for(fp), 1)
  t.eq(widgets.pins_for(fp)[1].object_id, "p2")

  widgets.unpin(fp, 1)
  t.eq(#widgets.pins_for(fp), 0)

  -- No object-id → refuse (nil), nothing stored.
  t.eq(widgets.toggle_pin(fp, "cellA", { name = "x", label = "y" }), nil)
  t.eq(#widgets.pins_for(fp), 0)
end)

-- ── nudge value math ──────────────────────────────────────────────────────

t.case("nudge: slider steps and clamps to its bounds", function()
  local w = { name = "slider", value = 5, options = { start = 0, stop = 10 } }
  t.eq(widget_picker.nudge_value(w, 1), 6)
  t.eq(widget_picker.nudge_value(w, -1), 4)
  w.value = 10
  t.eq(widget_picker.nudge_value(w, 1), 10, "clamped at stop")
  w.value = 0
  t.eq(widget_picker.nudge_value(w, -1), 0, "clamped at start")
  w.options.step = 0.5
  w.value = 5
  t.eq(widget_picker.nudge_value(w, 1), 5.5, "data-step honoured")
end)

t.case("nudge: number without bounds just moves", function()
  local w = { name = "number", value = 3.5, options = {} }
  t.eq(widget_picker.nudge_value(w, 1), 4.5)
  t.eq(widget_picker.nudge_value(w, -1), 2.5)
end)

t.case("nudge: range_slider shifts the whole window", function()
  local w = { name = "range_slider", value = { 20, 80 },
              options = { start = 0, stop = 100, step = 10 } }
  t.eq(widget_picker.nudge_value(w, 1), { 30, 90 })
  w.value = { 90, 100 }
  t.eq(widget_picker.nudge_value(w, 1), { 100, 100 }, "ends clamp independently")
end)

t.case("nudge: explicit steps list walks the list", function()
  local w = { name = "slider", value = 2,
              options = { start = 1, stop = 8, steps = "[1,2,4,8]" } }
  t.eq(widget_picker.nudge_value(w, 1), 4)
  t.eq(widget_picker.nudge_value(w, -1), 1)
  w.value = 8
  t.eq(widget_picker.nudge_value(w, 1), 8, "stays at the last step")
end)

t.case("nudge: empty steps list (the marimo default) is ignored", function()
  -- Real slider fixtures carry data-steps='[]' — must fall through to
  -- data-step arithmetic, not crash or freeze on an empty list.
  local w = { name = "slider", value = 5,
              options = { start = 0, stop = 10, steps = "[]" } }
  t.eq(widget_picker.nudge_value(w, 1), 6)
end)

t.case("nudge: non-nudgeable widgets return nil", function()
  t.eq(widget_picker.nudge_value({ name = "text", value = "x", options = {} }, 1), nil)
  t.eq(widget_picker.nudge_value({ name = "dropdown", value = "a", options = {} }, 1), nil)
end)

-- ── last-edited widget ────────────────────────────────────────────────────

t.case("last: set/get round-trips", function()
  local nb = { bufnr = 1, filepath = "/tmp/x.py" }
  widgets.set_last(nb, "cellZ", "obj9")
  local last = widgets.get_last()
  t.ok(last.nb == nb)
  t.eq(last.cell_id, "cellZ")
  t.eq(last.object_id, "obj9")
  widgets._last_widget = nil
end)

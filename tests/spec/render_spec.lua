-- Pipeline tests: real-marimo fixture HTML → tree_render → virt_lines.
-- Assertions are structural (what the user would see + what the widget
-- registry holds) rather than byte-golden, so cosmetic renderer tweaks
-- don't break the suite.

local t = require("helpers")
local tree_render = require("neo-marimo.tree_render")
local widgets = require("neo-marimo.widgets")

local _next_cell = 0

-- Fresh render context per case. Uses a real scratch buffer so the widget
-- registry path is exercised; a unique cell id isolates registries between
-- cases (output.lua clears the registry before each real render — tests
-- get isolation from the unique ids instead).
local function render_fixture(name)
  _next_cell = _next_cell + 1
  local ctx = {
    bufnr = vim.api.nvim_create_buf(false, true),
    cell_id = "test" .. _next_cell,
    row = 0,
    filepath = nil,
    image_drawn = false,
    skip_cap = false,
  }
  local virt = tree_render.render(t.fixture(name), ctx)
  return t.flat_lines(virt), ctx, widgets.list_for_cell(ctx.bufnr, ctx.cell_id)
end

local function names_of(reg)
  local out = {}
  for _, w in ipairs(reg) do table.insert(out, w.name) end
  return out
end

-- ── routing predicate ─────────────────────────────────────────────────────

t.case("render: wants() routes structure to the tree path only", function()
  t.ok(tree_render.wants(t.fixture("slider")), "slider → tree")
  t.ok(tree_render.wants(t.fixture("tabs_with_table")), "tabs → tree")
  t.ok(tree_render.wants(t.fixture("plain_html_table")), "html table → tree")
  t.ok(tree_render.wants(t.fixture("hstack_md")), "flex div → tree")
  t.ok(not tree_render.wants(t.fixture("md_simple")), "markdown → fast path")
  t.ok(not tree_render.wants(t.fixture("md_rich")), "rich markdown → fast path")
  t.ok(not tree_render.wants(t.fixture("html_img_datauri")), "data-uri img → fast path")
  t.ok(not tree_render.wants(t.fixture("html_svg_inline")), "inline svg → fast path")
end)

-- ── the cell-4 regression ─────────────────────────────────────────────────

t.case("render: tabs_with_table shows tabs AND the table (cell-4 bug)", function()
  local lines, ctx, reg = render_fixture("tabs_with_table")
  local joined = table.concat(lines, "\n")

  -- All three tab headers present.
  t.match(joined, "tab: Selectors")
  t.match(joined, "tab: Tables")
  t.match(joined, "tab: Refresh")
  -- The widgets inside the Selectors tab rendered.
  t.match(joined, "Slider")
  t.match(joined, "%[x%] Check")
  -- The dataframe inside the Tables tab rendered as an inline table —
  -- scoped to its tab, not replacing the whole payload.
  t.match(joined, "│ a")
  t.match(joined, "│ 1")
  t.no_match(joined, "_marimo_row_id")
  -- Tab headers must appear BEFORE the table (the old bug rendered only
  -- the table).
  t.ok(joined:find("tab: Selectors") < joined:find("│ a"),
    "tabs render around the table, table doesn't hijack")

  -- Interactive widgets registered in document order; the table is not a
  -- registry entry.
  t.eq(names_of(reg), { "slider", "checkbox", "refresh" })
  for _, w in ipairs(reg) do
    t.ok(w.object_id and #w.object_id > 0, w.name .. " has object-id")
  end

  t.ok(ctx.skip_cap, "widget payloads skip the line cap")
  -- Nothing leaked as raw markup.
  t.no_match(joined, "marimo%-")
  t.no_match(joined, "</")
end)

-- ── plain widgets ─────────────────────────────────────────────────────────

t.case("render: slider", function()
  local lines, _, reg = render_fixture("slider")
  local joined = table.concat(lines, "\n")
  t.match(joined, "Slider 0%-10: ")
  t.match(joined, "●")
  t.match(joined, "5")
  t.match(joined, "%(0‥10%)")
  t.eq(#reg, 1)
  t.eq(reg[1].name, "slider")
  t.eq(reg[1].value, 5)
  t.eq(reg[1].label, "Slider 0-10")
  t.ok(reg[1].object_id, "object-id hoisted from ui-element wrapper")
end)

t.case("render: slider override survives re-render", function()
  local _, _, reg = render_fixture("slider")
  local w = reg[1]
  widgets.set_override(w.object_id, 8)
  local lines2, _, reg2 = render_fixture("slider")
  t.eq(reg2[1].value, 8, "override applied on re-parse")
  t.match(table.concat(lines2, "\n"), "8")
  widgets.set_override(w.object_id, nil)
end)

t.case("render: range_slider shows the pair", function()
  local lines = render_fixture("range_slider")
  t.match(table.concat(lines, "\n"), "20‥80")
end)

t.case("render: checkbox checked with label", function()
  local lines = render_fixture("checkbox")
  t.match(table.concat(lines, "\n"), "%[x%] Enable option")
end)

t.case("render: switch off", function()
  local lines = render_fixture("switch")
  t.match(table.concat(lines, "\n"), "%[ %] A switch")
end)

t.case("render: text input", function()
  local lines, _, reg = render_fixture("text")
  t.match(table.concat(lines, "\n"), "Text input: ")
  t.match(table.concat(lines, "\n"), "hello")
  t.eq(reg[1].value, "hello")
end)

t.case("render: text_area box", function()
  local lines = render_fixture("text_area")
  local joined = table.concat(lines, "\n")
  t.match(joined, "multi%-line")
  t.match(joined, "text")
  t.match(joined, "╭")
  t.match(joined, "╰")
end)

t.case("render: number", function()
  local lines = render_fixture("number")
  t.match(table.concat(lines, "\n"), "3%.14")
end)

t.case("render: dropdown shows selection", function()
  local lines, _, reg = render_fixture("dropdown")
  t.match(table.concat(lines, "\n"), "banana")
  -- Picker contract: options JSON decodable from w.options.options.
  local ok, opts = pcall(vim.json.decode, reg[1].options.options)
  t.ok(ok and #opts == 3, "dropdown options decodable")
end)

t.case("render: radio shows selection and options decode", function()
  local lines, _, reg = render_fixture("radio")
  t.match(table.concat(lines, "\n"), "green")
  local ok, opts = pcall(vim.json.decode, reg[1].options.options)
  t.ok(ok and #opts == 3, "radio options decodable")
end)

t.case("render: multiselect", function()
  local lines = render_fixture("multiselect")
  t.match(table.concat(lines, "\n"), "Pick many")
end)

t.case("render: button + run_button", function()
  for _, f in ipairs({ "button", "run_button" }) do
    local lines, _, reg = render_fixture(f)
    t.match(table.concat(lines, "\n"), "MarimoWidget", f)
    t.eq(reg[1].name, "button")
  end
end)

t.case("render: refresh interval", function()
  local lines, _, reg = render_fixture("refresh")
  t.match(table.concat(lines, "\n"), "↻ refresh")
  t.match(table.concat(lines, "\n"), "every 1m")
  t.eq(reg[1].name, "refresh")
end)

t.case("render: unlabeled widgets don't show literal 'null'", function()
  -- run_button has data-label='null' in this marimo version… and even if
  -- not, a synthetic case nails it.
  local html_mod = require("neo-marimo.html")
  t.eq(html_mod.clean_label("null"), nil)
  local lines = render_fixture("run_button")
  t.no_match(table.concat(lines, "\n"), "null")
end)

-- ── tables / dataframes ───────────────────────────────────────────────────

t.case("render: marimo-table renders inline dataframe", function()
  local lines, ctx, reg = render_fixture("table")
  local joined = table.concat(lines, "\n")
  t.match(joined, "│ a")
  t.match(joined, "│ cat")
  t.no_match(joined, "_marimo_row_id")
  t.eq(#reg, 0, "tables aren't registry widgets")
  t.ok(not ctx.skip_cap, "table payloads keep the line cap")
end)

t.case("render: plain pandas to_html table", function()
  local lines = render_fixture("plain_html_table")
  local joined = table.concat(lines, "\n")
  t.match(joined, "│ a")
  t.match(joined, "│ 1")
end)

t.case("render: df_as_html (marimo-wrapped DataFrame)", function()
  local lines = render_fixture("df_as_html")
  t.match(table.concat(lines, "\n"), "│ a")
end)

-- ── layouts ───────────────────────────────────────────────────────────────

t.case("render: vstack stacks widgets with spacers", function()
  local lines, ctx, reg = render_fixture("vstack_widgets")
  local joined = table.concat(lines, "\n")
  t.match(joined, "Slider")
  t.match(joined, "%[x%] Check")
  t.match(joined, "Text")
  t.eq(names_of(reg), { "slider", "checkbox", "text" })
  t.ok(ctx.skip_cap)
end)

t.case("render: hstack stitches columns in a box", function()
  local lines, _, reg = render_fixture("hstack_widgets")
  t.match(lines[1] or "", "┌")
  t.match(lines[#lines] or "", "└")
  t.eq(#reg, 2, "both columns' widgets registered")
end)

t.case("render: hstack of markdown columns", function()
  local lines = render_fixture("hstack_md")
  local joined = table.concat(lines, "\n")
  t.match(joined, "┌")
  t.match(joined, "Left")
  t.match(joined, "Right col")
end)

t.case("render: nested stacks (hstack inside vstack)", function()
  local lines, _, reg = render_fixture("nested_stacks")
  local joined = table.concat(lines, "\n")
  t.match(joined, "┌", "inner hstack box present")
  t.match(joined, "below the row")
  t.eq(#reg, 3)
end)

t.case("render: tabs_simple labels and bodies", function()
  local lines, _, reg = render_fixture("tabs_simple")
  local joined = table.concat(lines, "\n")
  t.match(joined, "tab: A")
  t.match(joined, "tab: B")
  t.match(joined, "hello", "markdown tab body rendered")
  t.eq(names_of(reg), { "slider", "checkbox" })
end)

t.case("render: tabs_mixed markdown + dataframe tabs", function()
  local lines = render_fixture("tabs_mixed")
  local joined = table.concat(lines, "\n")
  t.match(joined, "tab: Markdown")
  t.match(joined, "tab: Data")
  t.match(joined, "Simple text in a tab")
  t.match(joined, "│ a", "table inside Data tab rendered")
end)

t.case("render: accordion sections", function()
  local lines, _, reg = render_fixture("accordion")
  local joined = table.concat(lines, "\n")
  t.match(joined, "▾ Section 1")
  t.match(joined, "▾ Section 2")
  t.match(joined, "body one")
  t.eq(names_of(reg), { "slider" }, "widget inside section registered")
end)

-- ── composites ────────────────────────────────────────────────────────────

t.case("render: callout kind + body", function()
  local lines = render_fixture("callout")
  local joined = table.concat(lines, "\n")
  t.match(joined, "▎ info")
  t.match(joined, "note body")
end)

t.case("render: form renders child widget + submit hint", function()
  local lines, _, reg = render_fixture("form")
  local joined = table.concat(lines, "\n")
  t.match(joined, "Submit")
  t.eq(names_of(reg), { "text" }, "inner widget registered")
  t.ok(reg[1].object_id, "inner widget keeps its own object-id")
end)

t.case("render: mo.ui.array as compact dict", function()
  local lines, _, reg = render_fixture("array")
  local joined = table.concat(lines, "\n")
  t.match(joined, "%[array%]")
  t.match(joined, '"A"')
  t.no_match(joined, "text/html", "json-output preview noise suppressed")
  t.eq(#reg, 0)
end)

-- ── placeholders ──────────────────────────────────────────────────────────

t.case("render: chart/explorer widgets get clean placeholders", function()
  local expectations = {
    altair_chart = "altair chart",
    plotly = "plotly chart",
    data_explorer = "data explorer",
    dataframe_widget = "dataframe transformer",
    file = "file upload",
  }
  for fixture, label in pairs(expectations) do
    local lines, _, reg = render_fixture(fixture)
    local joined = table.concat(lines, "\n")
    t.match(joined, label, fixture)
    t.match(joined, "open in browser", fixture)
    t.eq(#reg, 0, fixture .. " not in widget registry")
    t.no_match(joined, "value=%?", fixture .. " no unknown-widget noise")
  end
end)

t.case("render: unknown marimo element renders generically + registers", function()
  local ctx = {
    bufnr = vim.api.nvim_create_buf(false, true),
    cell_id = "unknown1", row = 0,
  }
  local virt = tree_render.render(
    "<marimo-ui-element object-id='x1'>"
      .. "<marimo-fancy data-initial-value='3'></marimo-fancy>"
      .. "</marimo-ui-element>",
    ctx
  )
  local joined = t.joined(virt)
  t.match(joined, "%[fancy%]")
  local reg = widgets.list_for_cell(ctx.bufnr, ctx.cell_id)
  t.eq(#reg, 1)
  t.eq(reg[1].object_id, "x1")
  t.eq(reg[1].value, 3)
end)

-- ── full corpus sweep ─────────────────────────────────────────────────────

t.case("render: no fixture renders raw marimo markup or crashes", function()
  for _, name in ipairs(t.fixture_names()) do
    -- Image fixtures route through the fast path in real use; rendering
    -- them here would touch image backends, so skip.
    if name ~= "html_img_datauri" and name ~= "html_svg_inline" then
      local lines = render_fixture(name)
      local joined = table.concat(lines, "\n")
      t.ok(#lines > 0, name .. " rendered something")
      t.no_match(joined, "<marimo%-", name)
      t.no_match(joined, "object%-id", name)
    end
  end
end)

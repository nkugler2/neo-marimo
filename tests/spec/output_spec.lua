-- Integration tests: output.M.render end-to-end — extmark attachment,
-- widget-registry lifecycle across re-renders, and the line cap.

local t = require("helpers")
local output = require("neo-marimo.output")
local widgets = require("neo-marimo.widgets")
local hl = require("neo-marimo.highlights")

local _next = 0

local function make_cell(bufnr, output_payload)
  _next = _next + 1
  -- Three buffer lines so start/end rows are real positions.
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x = 1", "y = 2", "z = 3" })
  return {
    id = "ocell" .. _next,
    index = 1,
    name = "_",
    start_row = 0,
    end_row = 2,
    status = "idle",
    _has_run = true,
    output = output_payload,
  }
end

local function virt_lines_at(bufnr)
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr, hl.ns_output, 0, -1, { details = true })
  local out = {}
  for _, m in ipairs(marks) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      local s = ""
      for _, ch in ipairs(vl) do s = s .. ch[1] end
      table.insert(out, s)
    end
  end
  return out
end

t.case("output: tabs payload attaches virt_lines and registers widgets", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local cell = make_cell(bufnr, {
    mimetype = "text/html",
    data = t.fixture("tabs_with_table"),
  })
  output.render(bufnr, cell)

  local lines = virt_lines_at(bufnr)
  local joined = table.concat(lines, "\n")
  t.ok(#lines > 10, "rich output attached (" .. #lines .. " lines)")
  t.match(joined, "✓ ran", "status line present")
  t.match(joined, "tab: Selectors")
  t.match(joined, "│ a", "table inside tab")
  t.no_match(joined, "truncated", "widget payloads skip the cap")

  local reg = widgets.list_for_cell(bufnr, cell.id)
  t.eq(#reg, 3, "widgets registered through the real render path")
end)

t.case("output: registry clears when output stops having widgets", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local cell = make_cell(bufnr, {
    mimetype = "text/html",
    data = t.fixture("vstack_widgets"),
  })
  output.render(bufnr, cell)
  t.eq(#widgets.list_for_cell(bufnr, cell.id), 3)

  cell.output = { mimetype = "text/plain", data = "now just text" }
  output.render(bufnr, cell)
  t.eq(#widgets.list_for_cell(bufnr, cell.id), 0,
    "stale widgets dropped on re-render")
  t.match(table.concat(virt_lines_at(bufnr), "\n"), "now just text")
end)

t.case("output: plain text over the cap is truncated", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local long = {}
  for i = 1, 60 do table.insert(long, "line " .. i) end
  local cell = make_cell(bufnr, {
    mimetype = "text/plain",
    data = table.concat(long, "\n"),
  })
  output.render(bufnr, cell)
  local joined = table.concat(virt_lines_at(bufnr), "\n")
  t.match(joined, "truncated")
  t.no_match(joined, "line 59", "tail capped")
  -- The hint names the escape hatches (11.6): toggle + browser, but not
  -- the dataframe panel for a non-table payload.
  t.match(joined, "<leader>mt")
  t.match(joined, "<leader>mo")
  t.no_match(joined, "<leader>mD", "no table hint for plain text")
end)

t.case("output: dataframe output points at the full panel", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local rows = {}
  for i = 1, 200 do rows[i] = { a = i, b = "x" .. i } end
  local cell = {
    id = "df-trunc", index = 1, name = "_",
    start_row = 0, end_row = 2, status = "idle", _has_run = true,
    output = {
      mimetype = "application/vnd.dataresource+json",
      data = {
        schema = { fields = { { name = "a" }, { name = "b" } } },
        data = rows,
      },
    },
  }
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x = 1", "y = 2", "z = 3" })
  -- The inline dataframe renderer caps itself at 5 rows, so this payload
  -- never trips MAX_LINES — but its own hint must still point at the panel.
  output.render(bufnr, cell)
  local joined = table.concat(virt_lines_at(bufnr), "\n")
  t.match(joined, "<leader>mD", "panel hint present for table output")
  t.match(joined, "195 more rows")
end)

t.case("output: full notebook.py cell-4 payload renders every tab", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local cell = make_cell(bufnr, {
    mimetype = "text/html",
    data = t.fixture("notebook_cell4"),
  })
  output.render(bufnr, cell)
  local joined = table.concat(virt_lines_at(bufnr), "\n")

  for _, tab in ipairs({ "Buttons", "Selectors", "Text & File",
                         "Tables", "Charts %(UI%)", "Refresh" }) do
    t.match(joined, "tab: " .. tab)
  end
  -- Spot-check one element of each family.
  t.match(joined, "Click me")
  t.match(joined, "Slider 0%-10")
  t.match(joined, "20‥80")
  t.match(joined, "Text input")
  t.match(joined, "│ a", "table renders inside its tab")
  t.match(joined, "altair chart")
  t.match(joined, "plotly chart")
  t.match(joined, "file upload")
  t.match(joined, "↻ refresh")
  t.no_match(joined, "<marimo%-")
  t.no_match(joined, "truncated")

  -- Every interactive widget across all tabs is in the registry.
  local reg = widgets.list_for_cell(bufnr, cell.id)
  local names = {}
  for _, w in ipairs(reg) do names[w.name] = (names[w.name] or 0) + 1 end
  t.eq(names.button, 2, "button + run_button")
  t.eq(names.slider, 1)
  t.eq(names.range_slider, 1)
  t.eq(names.checkbox, 1)
  t.eq(names.dropdown, 1)
  t.eq(names.radio, 1)
  t.eq(names.number, 1)
  t.eq(names.date, 1)
  t.eq(names.text, 1)
  t.eq(names.text_area, 1)
  t.eq(names.refresh, 1)
end)

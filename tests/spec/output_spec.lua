-- Integration tests: output.M.render end-to-end — extmark attachment,
-- widget-registry lifecycle across re-renders, and the line cap.

local t = require("helpers")
local output = require("neo-marimo.output")
local widgets = require("neo-marimo.widgets")
local hl = require("neo-marimo.highlights")
local markdown = require("neo-marimo.markdown")
local image = require("neo-marimo.image")

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

t.case("output: console output is capped on append and truncated on render (F2.3)", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local cell = make_cell(bufnr, { mimetype = "text/plain", data = "" })
  local nb = { cell_by_id = { [cell.id] = cell } }

  -- Simulate a print-heavy loop: one cell-op per print, each appending a
  -- single console entry — the exact growth pattern F2.3 guards against.
  for i = 1, 250 do
    output.handle_cell_op(bufnr, nb, {
      cell_id = cell.id,
      console = { channel = "stdout", mimetype = "text/plain", data = "line " .. i },
    })
  end

  t.ok(#cell.console <= 200,
    "stored console list bounded (" .. #cell.console .. " entries)")
  t.eq(cell.console[1].data, "line 51", "oldest entries dropped first")
  t.eq(cell.console[#cell.console].data, "line 250", "most recent entry kept")

  -- handle_cell_op defers the actual re-render via vim.schedule; render
  -- synchronously here so the test doesn't need to pump the event loop.
  output.render(bufnr, cell, nil)
  local joined = table.concat(virt_lines_at(bufnr), "\n")
  t.match(joined, "console output truncated")
  t.match(joined, "line 51", "earliest surviving entry still painted")
  t.no_match(joined, "line 250", "render stops at MAX_CONSOLE_LINES")
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

t.case("output: ns_output mark stays pinned to end_row across a gcc-style last-line rewrite", function()
  -- F2.1 regression: right_gravity defaulted to true, so replacing the
  -- cell's last line (delete+insert of that exact line — what a comment
  -- toggle like gcc does) rode the mark onto the next row, i.e. past this
  -- cell's boundary. right_gravity = false must keep it pinned to end_row.
  local bufnr = vim.api.nvim_create_buf(false, true)
  local cell = make_cell(bufnr, { mimetype = "text/plain", data = "hello" })
  output.render(bufnr, cell)

  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr, hl.ns_output, 0, -1, { details = true })
  t.eq(#marks, 1, "one output mark before the edit")
  t.eq(marks[1][2], cell.end_row, "mark starts at end_row")

  -- gcc-style rewrite: replace the exact last line (row 2, "z = 3") with
  -- new content — a delete + insert of that one line, buffer length
  -- unchanged.
  vim.api.nvim_buf_set_lines(bufnr, cell.end_row, cell.end_row + 1, false,
    { "# z = 3" })

  marks = vim.api.nvim_buf_get_extmarks(
    bufnr, hl.ns_output, 0, -1, { details = true })
  t.eq(#marks, 1, "still one output mark after the edit")
  t.eq(marks[1][2], cell.end_row,
    "mark stays pinned to end_row instead of riding onto the next row")
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

t.case("output: registered renderers receive a populated opts (F4.3)", function()
  -- F4.3: the documented (data, opts) contract used to hand every renderer
  -- an empty {} — a third-party renderer registered via register_renderer
  -- had no way to draw an image or register a widget, since only the
  -- built-ins could reach bufnr/cell_id/row through the private
  -- _render_ctx upvalue. Assert opts is now actually populated.
  local seen_opts
  output.register_renderer("application/vnd.neo-marimo-test+json", function(_data, opts)
    seen_opts = opts
    return { { { "  [test]", "MarimoOutputText" } } }
  end)

  local bufnr = vim.api.nvim_create_buf(false, true)
  local cell = make_cell(bufnr, {
    mimetype = "application/vnd.neo-marimo-test+json",
    data = { hello = "world" },
  })
  output.render(bufnr, cell, "/tmp/notebook.py")

  -- Clean up the registry entry immediately so a failure below can't leak
  -- this renderer into other specs. register_renderer(mime, nil) is the
  -- deregister path (plan-refinement F4.4) now that output's renderers
  -- table isn't reachable to splice directly.
  output.register_renderer("application/vnd.neo-marimo-test+json", nil)

  t.ok(seen_opts ~= nil, "renderer was invoked")
  t.eq(seen_opts.bufnr, bufnr, "opts.bufnr matches the rendering buffer")
  t.eq(seen_opts.cell_id, cell.id, "opts.cell_id matches the cell")
  t.eq(seen_opts.row, cell.end_row, "opts.row matches the cell's end_row")
  t.eq(seen_opts.filepath, "/tmp/notebook.py", "opts.filepath is forwarded")

  -- The deregister actually took effect: re-rendering the same mimetype now
  -- falls back to the generic "unknown mimetype" placeholder instead of
  -- reaching the (deregistered) custom renderer.
  output.render(bufnr, cell, "/tmp/notebook.py")
  t.match(table.concat(virt_lines_at(bufnr), "\n"),
    vim.pesc("[application/vnd.neo-marimo-test+json]"),
    "unknown-mimetype placeholder after deregister")
end)

t.case("output: a throwing renderer gets a placeholder, doesn't blank the cell or break other cells (F4.1)", function()
  -- F4.1: before the pcall wrap, a throwing renderer propagated into the
  -- cell-op WS handler's own pcall, which suppressed ALL further rendering
  -- with a misattributed "WS handler failed" warning — and because
  -- M.render clears ns_output before building new virt_lines, the throw
  -- left the cell silently blank. Assert the failure is contained to a
  -- visible placeholder and the rest of rendering still works.
  local mime = "application/vnd.neo-marimo-throws+json"
  output.register_renderer(mime, function()
    error("boom")
  end)

  local bufnr = vim.api.nvim_create_buf(false, true)
  local cell = make_cell(bufnr, { mimetype = mime, data = { x = 1 } })
  output.render(bufnr, cell)

  -- Deregister immediately so a failure below can't leak into other specs.
  -- register_renderer(mime, nil) is the deregister path (plan-refinement
  -- F4.4) now that output's renderers table isn't reachable to splice
  -- directly.
  output.register_renderer(mime, nil)

  local joined = table.concat(virt_lines_at(bufnr), "\n")
  t.match(joined, "renderer error", "placeholder line shown instead of a blank cell")
  -- vim.pesc: mime contains "+", a Lua pattern magic char.
  t.match(joined, vim.pesc(mime), "placeholder names the offending mimetype")

  -- A second, unrelated cell in the same buffer still renders fine.
  local other = make_cell(bufnr, { mimetype = "text/plain", data = "still fine" })
  output.render(bufnr, other)
  t.match(table.concat(virt_lines_at(bufnr), "\n"), "still fine",
    "an unrelated cell renders normally after the throwing renderer")

  -- The deregister actually took effect: re-rendering the same cell no
  -- longer reaches the (now-gone) throwing renderer, so the error
  -- placeholder is gone and the fallback "unknown mimetype" line shows
  -- instead.
  output.render(bufnr, cell)
  local rejoined = table.concat(virt_lines_at(bufnr), "\n")
  t.no_match(rejoined, "renderer error", "no longer routes to the deregistered renderer")
  t.match(rejoined, vim.pesc("[" .. mime .. "]"), "falls back to the unknown-mimetype placeholder")
end)

t.case("output: image_drawn is only set after a successful draw, so a throwing image render still cleans up the orphan (F4.1 review)", function()
  -- F4.1 follow-up: render_image (the built-in "image/*" renderer) used to
  -- set _render_ctx.image_drawn = true *before* calling image.render_base64.
  -- safe_render's pcall catches a throw there and shows the placeholder, but
  -- image_drawn was already true by then, so M.render's orphan-image cleanup
  -- (image.clear_for_cell, gated on image_drawn == false) never fired — a
  -- placement from a *previous* successful render would silently survive
  -- next to the new error placeholder. Stub image.render_base64 to throw and
  -- assert the cleanup still runs.
  local bufnr = vim.api.nvim_create_buf(false, true)
  -- Non-empty data: an empty string is treated as "no output" and never
  -- reaches the renderer at all (see the early-return in output_to_virt_lines).
  local cell = make_cell(bufnr, { mimetype = "image/png", data = "AAAA" })

  -- Stand in for a prior render's live placement.
  local closed = false
  image._register_for_test(bufnr, cell.id, "/tmp/fake.png", function() closed = true end)

  local orig_render_base64 = image.render_base64
  image.render_base64 = function() error("boom") end
  local ok = pcall(output.render, bufnr, cell)
  image.render_base64 = orig_render_base64

  t.ok(ok, "M.render itself doesn't raise even though the image renderer threw")
  t.ok(closed, "the orphaned placement was cleaned up despite the throw")
  t.match(table.concat(virt_lines_at(bufnr), "\n"), "renderer error",
    "the throw still surfaces as a placeholder")
end)

-- ── render_error (F6.3: previously zero test coverage) ────────────────────

t.case("output: render_error renders each error object in an array payload", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local cell = make_cell(bufnr, {
    mimetype = "application/vnd.marimo+error",
    data = {
      { type = "NameError", msg = "name 'x' is not defined" },
      { type = "SyntaxError", msg = "invalid syntax" },
    },
  })
  output.render(bufnr, cell)
  local joined = table.concat(virt_lines_at(bufnr), "\n")
  t.match(joined, "✖ NameError: name 'x' is not defined")
  t.match(joined, "✖ SyntaxError: invalid syntax")
end)

t.case("output: render_error falls back to \"Error\" when an entry has no type/msg", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local cell = make_cell(bufnr, {
    mimetype = "application/vnd.marimo+error",
    data = { "a bare string entry" },
  })
  output.render(bufnr, cell)
  local joined = table.concat(virt_lines_at(bufnr), "\n")
  t.match(joined, "✖ Error: a bare string entry")
end)

t.case("output: render_error stringifies a non-table payload", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local cell = make_cell(bufnr, {
    mimetype = "application/vnd.marimo+error",
    data = "kernel crashed",
  })
  output.render(bufnr, cell)
  local joined = table.concat(virt_lines_at(bufnr), "\n")
  t.match(joined, "✖ kernel crashed")
end)

t.case("output: render_error shows a visible fallback line for a non-array table payload (F6.3)", function()
  -- Before F6.3, a dict-shaped (or empty-array) error payload walked zero
  -- ipairs iterations and produced no virt_lines at all — a reported error
  -- that rendered as a silently blank cell. Assert it's visible now.
  local bufnr = vim.api.nvim_create_buf(false, true)
  local cell = make_cell(bufnr, {
    mimetype = "application/vnd.marimo+error",
    data = { kind = "not-an-array-shape" },
  })
  output.render(bufnr, cell)
  local joined = table.concat(virt_lines_at(bufnr), "\n")
  t.match(joined, "✖ Error %(unrecognized payload%)")
end)

t.case("highlights: MarimoOutputText is readable, not a dim/italic Comment link (F2.4)", function()
  -- F2.4: MarimoOutputText used to `link = "Comment"`, which is dim + italic
  -- in most colorschemes and made all plain repr() output unreadable.
  hl.setup()
  local def = vim.api.nvim_get_hl(0, { name = "MarimoOutputText" })
  t.ok(def.link ~= "Comment", "no longer linked to Comment")
  t.ok(not def.italic, "not italic")
  t.ok(def.fg ~= nil, "has its own foreground color")
end)

t.case("highlights: MarimoMarkdownText exists and is readable (F2.4)", function()
  -- Split from MarimoOutputText so markdown prose and plain output can be
  -- tuned independently, without reintroducing the dim/italic Comment link.
  hl.setup()
  local def = vim.api.nvim_get_hl(0, { name = "MarimoMarkdownText" })
  t.ok(def.link ~= "Comment", "no longer linked to Comment")
  t.ok(not def.italic, "not italic")
  t.ok(def.fg ~= nil, "has its own foreground color")
end)

t.case("highlights: markdown prose uses MarimoMarkdownText, not MarimoOutputText (F2.4)", function()
  local virt = markdown.render("plain unmarked paragraph text")
  t.eq(#virt, 1, "one rendered line")
  local groups = {}
  for _, ch in ipairs(virt[1]) do groups[ch[2]] = true end
  t.ok(groups["MarimoMarkdownText"], "prose base chunk uses MarimoMarkdownText")
  t.ok(not groups["MarimoOutputText"], "markdown path no longer references MarimoOutputText")
end)

t.case("highlights: plain repr() output still uses MarimoOutputText (F2.4)", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local cell = make_cell(bufnr, { mimetype = "text/plain", data = "42" })
  output.render(bufnr, cell)

  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr, hl.ns_output, 0, -1, { details = true })
  local groups = {}
  for _, m in ipairs(marks) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      for _, ch in ipairs(vl) do groups[ch[2]] = true end
    end
  end
  t.ok(groups["MarimoOutputText"], "plain output still uses MarimoOutputText")
end)

-- ── viewport freeze across a render pass ────────────────────────────────────
--
-- A cell re-renders several times per run (queued → running → idle w/
-- output), each pass swapping the cell's virt_lines for a different line
-- count. With the cursor below the cell, that transient height change used
-- to be able to leave the window's topline nudged even once the final
-- output settled back to its original size. render() now snapshots each
-- window's topline before touching the extmark and restores it after.

t.case("output: topline is unchanged across a queued/running/idle sequence that ends at the same size", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local lines = { "x = 1", "y = 2", "z = 3" }
  for i = 1, 30 do table.insert(lines, "below " .. i) end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(win, 10)
  -- Cursor well below the cell (rows 0-2), so the cell's output height
  -- factors into how many screen rows separate topline and the cursor.
  vim.api.nvim_win_set_cursor(win, { 10, 0 })
  vim.fn.winrestview({ topline = 1 })

  local cell = {
    id = "topline-cell", index = 1, name = "_",
    start_row = 0, end_row = 2, status = "idle", _has_run = true,
  }
  local big = {}
  for i = 1, 8 do big[i] = "plot row " .. i end

  cell.output = { mimetype = "text/plain", data = table.concat(big, "\n") }
  output.render(bufnr, cell)
  vim.cmd("redraw")
  local stable_topline = vim.fn.winsaveview().topline

  -- Widget value change: queued/running shrinks the cell to its 1-line
  -- status placeholder…
  cell.status = "running"
  cell.output = nil
  output.render(bufnr, cell)
  vim.cmd("redraw")
  t.eq(vim.fn.winsaveview().topline, stable_topline,
    "topline unchanged during the running placeholder")

  -- …then idle restores the same-size output.
  cell.status = "idle"
  cell.output = { mimetype = "text/plain", data = table.concat(big, "\n") }
  output.render(bufnr, cell)
  vim.cmd("redraw")
  t.eq(vim.fn.winsaveview().topline, stable_topline,
    "topline unchanged once the final output resettles")
end)

t.case("output: a cell's first large render still scrolls the window to keep the cursor visible", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local lines = { "x = 1", "y = 2", "z = 3" }
  for i = 1, 30 do table.insert(lines, "below " .. i) end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(win, 10)
  vim.api.nvim_win_set_cursor(win, { 5, 0 })
  vim.fn.winrestview({ topline = 1 })

  local cell = {
    id = "topline-cell-2", index = 1, name = "_",
    start_row = 0, end_row = 2, status = "idle", _has_run = true,
  }
  local big = {}
  for i = 1, 20 do big[i] = "plot row " .. i end
  cell.output = { mimetype = "text/plain", data = table.concat(big, "\n") }
  output.render(bufnr, cell)
  vim.cmd("redraw")

  local view = vim.fn.winsaveview()
  local info = vim.fn.getwininfo(win)[1]
  t.ok(view.lnum >= info.topline and view.lnum <= info.botline,
    "cursor still visible — the freeze doesn't block a genuinely required scroll")
end)

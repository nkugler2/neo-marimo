-- lsp.lua position-mapping coverage: notebook_to_shadow_pos /
-- shadow_to_notebook_pos are the pure (row, col) translation pair the
-- whole shadow-buffer LSP bridge depends on (hover, completion,
-- signature help, goto-definition all route through them). No LSP
-- server is involved in any of these cases — everything here is buffer
-- and table math.
--
-- shadow_to_notebook_pos is local to lsp.lua; it's exported as
-- M.shadow_to_notebook_pos purely as a test seam (see the comment at its
-- definition). notebook_to_shadow_pos was already exported for blink.cmp.

local t = require("helpers")
local lsp = require("neo-marimo.lsp")

-- ── Part 1: pure math on hand-built nb/entry tables ────────────────────────
-- No buffer, no notebook harness — just the (row, col) arithmetic, including
-- shapes that can't occur from a real notebook buffer (cells are always
-- contiguous there) but that the functions must still handle defensively.

local function fake_cell(start_row, end_row)
  return { start_row = start_row, end_row = end_row }
end

t.case("lsp: notebook_to_shadow_pos returns nil when entry has no offsets yet", function()
  local nb = { cells = { fake_cell(0, 2) } }
  local entry = { cell_offsets = {} }
  local sr, sc = lsp.notebook_to_shadow_pos(nb, entry, 0, 0)
  t.eq(sr, nil)
  t.eq(sc, nil)
end)

t.case("lsp: notebook_to_shadow_pos returns nil for a row before the first cell", function()
  local nb = { cells = { fake_cell(3, 5) } }
  local entry = { cell_offsets = { [1] = { shadow_start_row = 1, col_shift = 0 } } }
  local sr = lsp.notebook_to_shadow_pos(nb, entry, 0, 0)
  t.eq(sr, nil)
end)

t.case("lsp: notebook_to_shadow_pos returns nil for a row past the last cell", function()
  local nb = { cells = { fake_cell(0, 2) } }
  local entry = { cell_offsets = { [1] = { shadow_start_row = 1, col_shift = 0 } } }
  local sr = lsp.notebook_to_shadow_pos(nb, entry, 99, 0)
  t.eq(sr, nil)
end)

-- Real notebook cells never have a row gap between them (buffer.lua's
-- cells_to_lines packs them contiguously), but the function iterates
-- cells independently of that invariant, so exercise the gap directly.
t.case("lsp: notebook_to_shadow_pos returns nil for a row in a synthetic inter-cell gap", function()
  local nb = { cells = { fake_cell(0, 2), fake_cell(5, 7) } }
  local entry = {
    cell_offsets = {
      [1] = { shadow_start_row = 1, col_shift = 0 },
      [2] = { shadow_start_row = 6, col_shift = 0 },
    },
  }
  local sr = lsp.notebook_to_shadow_pos(nb, entry, 3, 0)
  t.eq(sr, nil, "row 3 falls in the gap between cell 1 (ends at 2) and cell 2 (starts at 5)")
end)

t.case("lsp: notebook_to_shadow_pos returns nil when a cell has no matching offset entry", function()
  local nb = { cells = { fake_cell(0, 2) } }
  local entry = { cell_offsets = {} }
  entry.cell_offsets[1] = nil
  -- Non-empty offsets table (so the early #==0 guard doesn't fire) but no
  -- entry for cell 1 specifically.
  entry.cell_offsets[2] = { shadow_start_row = 0, col_shift = 0 }
  local sr = lsp.notebook_to_shadow_pos(nb, entry, 1, 0)
  t.eq(sr, nil)
end)

t.case("lsp: notebook_to_shadow_pos applies shadow_start_row and col_shift", function()
  local nb = { cells = { fake_cell(10, 12) } }
  local entry = { cell_offsets = { [1] = { shadow_start_row = 4, col_shift = 2 } } }
  -- Row 11 is the second line of the cell (offset 1 from start_row 10).
  local sr, sc, ci = lsp.notebook_to_shadow_pos(nb, entry, 11, 3)
  t.eq(sr, 5, "shadow row = shadow_start_row(4) + (11-10)")
  t.eq(sc, 5, "shadow col = col(3) + col_shift(2)")
  t.eq(ci, 1, "reports the matched cell index")
end)

t.case("lsp: shadow_to_notebook_pos returns nil when entry has no cell_offsets at all", function()
  local nb = { cells = { fake_cell(0, 2) } }
  local entry = {}
  local nr = lsp.shadow_to_notebook_pos(nb, entry, 0, 0)
  t.eq(nr, nil)
end)

t.case("lsp: shadow_to_notebook_pos returns nil for a shadow row outside every cell's shadow range", function()
  local nb = { cells = { fake_cell(0, 1) } }  -- 2-line cell
  local entry = { cell_offsets = { [1] = { shadow_start_row = 1, col_shift = 0 } } }
  -- Cell occupies shadow rows [1, 2] (2 lines). Row 0 is the marker line
  -- above it; row 3 is past it.
  t.eq(lsp.shadow_to_notebook_pos(nb, entry, 0, 0), nil, "marker/separator row above the cell")
  t.eq(lsp.shadow_to_notebook_pos(nb, entry, 3, 0), nil, "row past the cell's shadow range")
end)

t.case("lsp: shadow_to_notebook_pos clamps a negative resulting column to 0", function()
  local nb = { cells = { fake_cell(0, 1) } }
  local entry = { cell_offsets = { [1] = { shadow_start_row = 1, col_shift = 5 } } }
  local nr, nc = lsp.shadow_to_notebook_pos(nb, entry, 1, 2)
  t.eq(nr, 0)
  t.eq(nc, 0, "col(2) - col_shift(5) would be negative; clamped to 0")
end)

t.case("lsp: notebook_to_shadow_pos / shadow_to_notebook_pos round-trip on synthetic offsets", function()
  local nb = { cells = { fake_cell(0, 1), fake_cell(2, 4) } }
  local entry = {
    cell_offsets = {
      [1] = { shadow_start_row = 1, col_shift = 0 },
      [2] = { shadow_start_row = 5, col_shift = 0 },
    },
  }
  for _, pos in ipairs({ { 0, 0 }, { 1, 7 }, { 2, 0 }, { 3, 4 }, { 4, 9 } }) do
    local row, col = pos[1], pos[2]
    local sr, sc = lsp.notebook_to_shadow_pos(nb, entry, row, col)
    t.ok(sr ~= nil, "row " .. row .. " should map into the shadow")
    local nr, nc = lsp.shadow_to_notebook_pos(nb, entry, sr, sc)
    t.eq(nr, row, "round-trip row for notebook (" .. row .. "," .. col .. ")")
    t.eq(nc, col, "round-trip col for notebook (" .. row .. "," .. col .. ")")
  end
end)

-- ── Part 2: through the real shadow-buffer pipeline ────────────────────────
-- Builds a live notebook (real buffer, real cell anchors) via the shared
-- harness, then calls the public M.refresh_shadow wrapper so cell_offsets
-- come from the real build_shadow_text/transform_returns machinery rather
-- than being hand-rolled. No LSP client is attached (ensure_lsp_attached is
-- best-effort and just fires a FileType autocmd when none is found), so
-- this runs headless with no marimo/python dependency.

t.case("lsp: refresh_shadow builds cell_offsets that mark markers/separators as unmapped", function()
  local nb = t.make_notebook({
    "import numpy as np\nx = 1",                    -- cell 1: 2 lines
    "def f():\n    return 1\ny = x + 1",             -- cell 2: 3 lines, nested return untouched
    "return 99",                                     -- cell 3: 1 line, top-level return rewritten
  })

  local entry = lsp.refresh_shadow(nb)
  t.ok(entry, "refresh_shadow returns an entry")
  t.eq(#entry.cell_offsets, 3)

  local shadow_lines = vim.api.nvim_buf_get_lines(entry.bufnr, 0, -1, false)
  t.eq(shadow_lines, {
    "#@cell 1 [python]",
    "import numpy as np",
    "x = 1",
    "",
    "#@cell 2 [python]",
    "def f():",
    "    return 1",
    "y = x + 1",
    "",
    "#@cell 3 [python]",
    "_RET = 99",
    "",
  })

  -- Marker lines (0, 4, 9) and blank separators (3, 8, 11) sit between/around
  -- cells in shadow coordinates and must not resolve to any notebook cell —
  -- this is the shadow-side analogue of "before first cell" (row 0),
  -- "between cells" (rows 3, 4, 8, 9), and "past the last cell" (row 11).
  for _, shadow_row in ipairs({ 0, 3, 4, 8, 9, 11 }) do
    t.eq(lsp.shadow_to_notebook_pos(nb, entry, shadow_row, 0), nil,
      "shadow row " .. shadow_row .. " (marker/separator) must not map into a cell")
  end

  -- A shadow row well past the end of the buffer is equally unmapped.
  t.eq(lsp.shadow_to_notebook_pos(nb, entry, 999, 0), nil)
end)

t.case("lsp: refresh_shadow rewrites a top-level `return` but leaves a nested one untouched", function()
  local nb = t.make_notebook({
    "def f():\n    return 1\ny = 2",
    "return 99",
  })
  local entry = lsp.refresh_shadow(nb)
  local shadow_lines = vim.api.nvim_buf_get_lines(entry.bufnr, 0, -1, false)
  local joined = table.concat(shadow_lines, "\n")
  t.match(joined, "    return 1", "indented return inside a nested def is left alone")
  t.match(joined, "_RET = 99", "top-level return is rewritten to a module-scope assignment")
  t.no_match(joined, "\nreturn 99", "the rewritten line no longer contains a bare top-level return")
end)

t.case("lsp: notebook_to_shadow_pos maps cell boundary lines (first and last row of each cell)", function()
  local nb = t.make_notebook({
    "a = 1\nb = 2\nc = 3",   -- cell 1: rows 0-2
    "d = 4",                 -- cell 2: row 3
  })
  local entry = lsp.refresh_shadow(nb)

  local cell1, cell2 = nb.cells[1], nb.cells[2]
  local off1, off2 = entry.cell_offsets[1], entry.cell_offsets[2]

  local sr = lsp.notebook_to_shadow_pos(nb, entry, cell1.start_row, 0)
  t.eq(sr, off1.shadow_start_row, "first row of cell 1 maps to its shadow_start_row")

  sr = lsp.notebook_to_shadow_pos(nb, entry, cell1.end_row, 0)
  t.eq(sr, off1.shadow_start_row + (cell1.end_row - cell1.start_row),
    "last row of cell 1 maps to the last shadow row of its code block")

  sr = lsp.notebook_to_shadow_pos(nb, entry, cell2.start_row, 0)
  t.eq(sr, off2.shadow_start_row, "single-line cell 2's only row maps to its shadow_start_row")
end)

t.case("lsp: notebook -> shadow -> notebook round-trip for in-cell positions across multiple cells", function()
  local nb = t.make_notebook({
    "import numpy as np\nx = np.array([1, 2, 3])",
    "def f():\n    return 1\ny = x + 1",
    "return 99",
  })
  local entry = lsp.refresh_shadow(nb)

  local positions = {}
  for _, cell in ipairs(nb.cells) do
    for row = cell.start_row, cell.end_row do
      table.insert(positions, { row, 0 })
      table.insert(positions, { row, 3 })
    end
  end

  for _, pos in ipairs(positions) do
    local row, col = pos[1], pos[2]
    local sr, sc = lsp.notebook_to_shadow_pos(nb, entry, row, col)
    t.ok(sr ~= nil, "in-cell notebook position (" .. row .. "," .. col .. ") must map to the shadow")
    local nr, nc = lsp.shadow_to_notebook_pos(nb, entry, sr, sc)
    t.eq(nr, row, "round-trip row for (" .. row .. "," .. col .. ")")
    t.eq(nc, col, "round-trip col for (" .. row .. "," .. col .. ")")
  end
end)

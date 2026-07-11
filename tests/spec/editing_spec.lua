-- Integration tests for the stateful editing core: cell tracking via extmark
-- anchors (buffer.lua), structural actions (actions.lua), undo restore
-- (notebook.lua), and remote patching (sync.lua). These are the modules where
-- every historical data-corruption bug lived (see plan-phases-7-15.md §7.5);
-- each case here pins one of those scenarios so it can't silently regress.
--
-- The harness (helpers.make_notebook) builds a real marimo:// buffer with the
-- production change-tracking (and buffer-local boundary keymaps) attached,
-- then drives it like a user would: nvim_buf_set_lines for typing, :normal!
-- for unmapped motions, :normal (no bang) where a cell-boundary keymap
-- (smart paste, `o`) needs to fire, :undo for undo. t.assert_consistent
-- re-checks the save validator's invariants after every mutation.

local t = require("helpers")
local notebook = require("neo-marimo.notebook")
local actions = require("neo-marimo.actions")
local sync = require("neo-marimo.sync")

t.case("editing: create renders a contiguous cell cover", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = a + 1\nprint(b)", "c = 3" })
  t.eq(#nb.cells, 3)
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    { "a = 1", "b = a + 1", "print(b)", "c = 3" })
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: typing inside a cell updates only that cell", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2", "c = 3" })
  -- Type the way a user does (insert-mode edits keep the anchors honest;
  -- a set_lines replacement would drag the right-gravity anchors past the
  -- new content — the smart-paste trap, not a typing shape).
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("normal! A0")        -- "b = 2"  → "b = 20"
  -- `o` here fires on the cursor cell's LAST line with a next cell present
  -- (a boundary case, plan-refinement F3.1) — mapped `normal` (no bang) so
  -- the buffer-local `o` keymap's A<CR> rewrite grows this cell instead of
  -- donating the opened line to cell 3.
  vim.cmd("normal obb = b")   -- open a new line inside cell 2
  nb._flush_pending()
  t.eq(nb.cells[2].code, "b = 20\nbb = b")
  t.eq(nb.cells[1].code, "a = 1")
  t.eq(nb.cells[3].code, "c = 3")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: new cell below mid-notebook (7.5.1)", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2", "c = 3" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  actions.new_cell_below(bufnr, nb)
  t.eq(#nb.cells, 4)
  t.eq(nb.cells[3].code, "")
  t.assert_consistent(nb, bufnr)

  -- Typing into the fresh cell lands in it, not a neighbour. The action
  -- parked the cursor on the new empty row.
  vim.cmd("normal! ad = 4")
  nb._flush_pending()
  t.eq(nb.cells[3].code, "d = 4")
  t.eq(nb.cells[2].code, "b = 2")
  t.eq(nb.cells[4].code, "c = 3")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: new cell above the first cell", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  actions.new_cell_above(bufnr, nb)
  t.eq(#nb.cells, 3)
  t.eq(nb.cells[1].code, "")
  t.eq(nb.cells[2].code, "a = 1")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: repeated new-cell keeps every line owned (7.5.1)", function()
  local nb, bufnr = t.make_notebook({ "a = 1" })
  for i = 1, 4 do
    actions.new_cell_below(bufnr, nb)
    vim.cmd("normal! ax" .. i .. " = " .. i)
    nb._flush_pending()
    t.assert_consistent(nb, bufnr, "after new-cell round " .. i)
  end
  t.eq(#nb.cells, 5)
end)

-- ── plan-refinement F3.1: cell-boundary anchor redesign ──────────────────
-- These pin the three boundary-insert scenarios that a single start-only
-- anchor could never disambiguate (see docs/plan-refinement.md F3.1): typing
-- across an `<CR>` into a fresh cell, `O` on a cell's first line, and `o` at
-- the end of a cell that isn't the last. The two `o` cases go through
-- `normal` (mapped, no bang) so the buffer-local boundary keymap fires —
-- script-driven `normal!` bypasses mappings and always lands in the "donate
-- to next cell" shape (documented as an accepted quirk in keymaps.lua).

t.case("editing: typing two lines with <CR> into a fresh new cell stays in it (F3.1)", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "c = 3" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  actions.new_cell_below(bufnr, nb) -- parks the cursor on the new empty row
  -- Real insert-mode <CR> splice (not feedkeys, but the same synchronous
  -- byte shape): before the fix, everything typed before the first <CR>
  -- landed in the PRECEDING cell (the TOCHANGE "pressing Enter goes to new
  -- cell" bug).
  vim.cmd([[execute "normal! ix = 1\ry = 2"]])
  nb._flush_pending()
  t.eq(nb.cells[1].code, "a = 1")
  t.eq(nb.cells[2].code, "x = 1\ny = 2")
  t.eq(nb.cells[3].code, "c = 3")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: O on a cell's first line keeps the opened line in that cell (F3.1)", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2", "c = 3" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- "b = 2", cell 2's first line
  vim.cmd([[execute "normal! Ox = 0"]]) -- anchors alone must fix this — no keymap involved
  nb._flush_pending()
  t.eq(nb.cells[1].code, "a = 1")
  t.eq(nb.cells[2].code, "x = 0\nb = 2")
  t.eq(nb.cells[3].code, "c = 3")
  t.assert_consistent(nb, bufnr)

  -- Sub-case: `O` on the very first cell's first line has no preceding
  -- cell to donate to, but must still keep start_row pinned at 0 rather
  -- than drifting.
  local nb2, bufnr2 = t.make_notebook({ "a = 1", "b = 2" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd([[execute "normal! Oz = 0"]])
  nb2._flush_pending()
  t.eq(nb2.cells[1].start_row, 0)
  t.eq(nb2.cells[1].code, "z = 0\na = 1")
  t.assert_consistent(nb2, bufnr2)
end)

t.case("editing: o at the end of a cell grows that cell (F3.1)", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- cell 1's only (= last) line
  vim.cmd("normal ox = 9") -- mapped: this is the boundary-aware `o` keymap under test
  nb._flush_pending()
  t.eq(nb.cells[1].code, "a = 1\nx = 9")
  t.eq(nb.cells[2].code, "b = 2")
  t.assert_consistent(nb, bufnr)

  -- Sub-case: `o` NOT on a cell's end_row (mid multi-line cell) is
  -- unaffected by the boundary rewrite — still opens an interior line.
  local nb2, bufnr2 = t.make_notebook({ "a = 1\nb = 2\nc = 3" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- "b = 2", not the cell's last line
  vim.cmd("normal ox = 9")
  nb2._flush_pending()
  t.eq(nb2.cells[1].code, "a = 1\nb = 2\nx = 9\nc = 3")
  t.assert_consistent(nb2, bufnr2)
end)

t.case("editing: whole-line replace at a boundary keeps ownership (gcc shape, F3.1)", function()
  -- Pins the pulled-back-start clamp + pass-3 renormalization (probe 5):
  -- a whole-line nvim_buf_set_lines replacement of cell 1's only line
  -- pulls cell 2's gravity-false start endpoint back onto row 0 unless the
  -- sync resolver clamps it forward again.
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2" })
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "# a = 1" })
  nb._flush_pending()
  t.eq(nb.cells[1].code, "# a = 1")
  t.eq(nb.cells[2].code, "b = 2")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: linewise p on a cell's last row pastes into that cell (F3.1)", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- cell 1's only (= last) line
  vim.fn.setreg('"', "x = 9\n", "V")
  vim.cmd("normal p") -- mapped smart-paste keymap's new non-empty-cell branch
  nb._flush_pending()
  t.eq(nb.cells[1].code, "a = 1\nx = 9")
  t.eq(nb.cells[2].code, "b = 2")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: delete cell keeps neighbours intact", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2\nprint(b)", "c = 3" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  actions.delete_cell_at_cursor(bufnr, nb)
  t.eq(#nb.cells, 2)
  t.eq(nb.cells[1].code, "a = 1")
  t.eq(nb.cells[2].code, "c = 3")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: refuses to delete the only cell", function()
  local nb, bufnr = t.make_notebook({ "a = 1" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  actions.delete_cell_at_cursor(bufnr, nb)
  t.eq(#nb.cells, 1)
  t.eq(nb.cells[1].code, "a = 1")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: prune_phantoms never empties the notebook (plan-refinement F1.5)", function()
  local cell_mod = require("neo-marimo.cell")
  -- Synthesize a compound-delete aftermath: three cells whose ranges all
  -- collapsed (end_row < start_row) in the same buffer edit, as if a single
  -- change swallowed every remaining cell's rows at once. With no last-cell
  -- guard this would prune all three down to `nb.cells == {}`.
  local nb = { cells = {}, cell_by_id = {} }
  for i = 1, 3 do
    local c = cell_mod.new({ code = "" }, i)
    c.start_row = 5
    c.end_row = 4 -- collapsed
    table.insert(nb.cells, c)
    nb.cell_by_id[c.id] = c
  end

  local removed = notebook.prune_phantoms(nb)

  t.eq(removed, 2, "two of the three collapsed cells are pruned")
  t.eq(#nb.cells, 1, "one cell always survives as the least-broken candidate")
  t.eq(nb.cell_by_id[nb.cells[1].id], nb.cells[1], "cell_by_id stays consistent with the survivor")
end)

t.case("editing: prune_phantoms spares the cell with the most surviving lines", function()
  local cell_mod = require("neo-marimo.cell")
  -- Same total-collapse scenario, but one candidate is "less collapsed"
  -- than the others (a smaller negative range) — it should be the one kept.
  local nb = { cells = {}, cell_by_id = {} }
  -- score = end_row - start_row: cell 1 and 3 are -1 (less collapsed), cell
  -- 2 is -2 (more collapsed). Cell 1 wins as the first cell to reach the
  -- best score (ties broken by earliest original index).
  local ranges = { { 5, 4 }, { 5, 3 }, { 5, 4 } }
  for i, r in ipairs(ranges) do
    local c = cell_mod.new({ code = "" }, i)
    c.start_row = r[1]
    c.end_row = r[2]
    table.insert(nb.cells, c)
    nb.cell_by_id[c.id] = c
  end
  local most_surviving_id = nb.cells[1].id

  notebook.prune_phantoms(nb)

  t.eq(#nb.cells, 1)
  t.eq(nb.cells[1].id, most_surviving_id, "the candidate with the least-collapsed range survives")
end)

t.case("editing: dead-anchor sweep never empties the notebook when every anchor is invalidated at once (plan-refinement F1.5 finding #1)", function()
  local buffer = require("neo-marimo.buffer")
  local hl = require("neo-marimo.highlights")
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2\nprint(b)", "c = 3" })
  t.eq(#nb.cells, 3)

  -- Synthesize a total anchor wipeout: delete every cell's start-anchor
  -- extmark out from under it directly (ordinary content edits reliably
  -- shift point extmarks rather than invalidate them, so this is the
  -- reliable way to force nvim_buf_get_extmark_by_id to come back empty for
  -- all of them in one sync — the compound-edit shape that, without a
  -- last-survivor guard on buffer.lua's dead-anchor sweep, would walk the
  -- first pass all the way to `nb.cells == {}` before prune_phantoms ever
  -- got a chance to run).
  for _, cell in ipairs(nb.cells) do
    vim.api.nvim_buf_del_extmark(bufnr, hl.ns_cell_anchor, cell.anchor_mark_id)
  end
  buffer.sync_cells_from_extmarks(bufnr, nb)

  t.eq(#nb.cells, 1, "one cell always survives a total anchor wipeout")
  t.eq(nb.cell_by_id[nb.cells[1].id], nb.cells[1], "cell_by_id stays consistent with the survivor")
end)

t.case("editing: survivor's dead anchor doesn't crash resolution when siblings live (code review follow-up)", function()
  -- Pins a nil-`content_end` crash found in review: the designated
  -- survivor (here cell 1, the largest — see the survivor-scoring comment
  -- in sync_cells_from_extmarks) has ONLY its own anchor force-deleted,
  -- while cells 2/3 keep theirs. Pass 1's survivor-fallback branch used to
  -- build `raw[cell]` without `content_end`, and pass 3 always reads
  -- `r.content_end` for every non-last cell (`math.max(r.content_end, ...)`)
  -- — so resolving the survivor (not the last cell here) threw
  -- "bad argument #1 to 'max'" instead of resolving to a sane span.
  local buffer = require("neo-marimo.buffer")
  local hl = require("neo-marimo.highlights")
  local nb, bufnr = t.make_notebook({ "a = 1\nprint(a)\nmore(a)", "b = 2", "c = 3" })
  t.eq(#nb.cells, 3)

  vim.api.nvim_buf_del_extmark(bufnr, hl.ns_cell_anchor, nb.cells[1].anchor_mark_id)

  local ok, err = pcall(buffer.sync_cells_from_extmarks, bufnr, nb)
  t.ok(ok, "sync_cells_from_extmarks must not error: " .. tostring(err))

  t.ok(#nb.cells > 0, "notebook must not be emptied")
  t.eq(nb.cells[2].code, "b = 2", "cell 2 survives untouched")
  t.eq(nb.cells[3].code, "c = 3", "cell 3 survives untouched")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: undo of delete-cell restores id and code (7.5.5)", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2\nprint(b)", "c = 3" })
  local deleted_id = nb.cells[2].id
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  t.undo_break()
  actions.delete_cell_at_cursor(bufnr, nb)
  t.eq(#nb.cells, 2)

  vim.cmd("silent undo")
  nb._flush_pending()
  t.eq(#nb.cells, 3)
  t.eq(nb.cells[2].id, deleted_id, "restored cell keeps its original id")
  t.eq(nb.cells[2].code, "b = 2\nprint(b)")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: dd on a one-line cell prunes it; undo restores (7.5.6)", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2", "c = 3" })
  local id2 = nb.cells[2].id
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  t.undo_break()
  vim.cmd("normal! dd")
  nb._flush_pending()
  t.eq(#nb.cells, 2)
  t.assert_consistent(nb, bufnr)

  vim.cmd("silent undo")
  nb._flush_pending()
  t.eq(#nb.cells, 3)
  t.eq(nb.cells[2].id, id2)
  t.eq(nb.cells[2].code, "b = 2")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: multi-line delete spanning cells (7.5.3)", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2", "c = 3", "d = 4", "e = 5" })
  -- V2jd from row 2 deletes rows 2-4 — cells b, c, d in one delete.
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("normal! V2jd")
  nb._flush_pending()
  t.eq(#nb.cells, 2)
  t.eq(nb.cells[1].code, "a = 1")
  t.eq(nb.cells[2].code, "e = 5")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: undo of multi-cell delete restores every id and code (plan-refinement F1.1)", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2", "c = 3", "d = 4", "e = 5" })
  local id_a, id_b, id_c, id_d, id_e =
    nb.cells[1].id, nb.cells[2].id, nb.cells[3].id, nb.cells[4].id, nb.cells[5].id

  -- V2jd from row 2 deletes rows 2-4 — cells b, c, d in one delete. Vim's
  -- undo restores that whole span as a single on_bytes insertion, so this
  -- pins the contiguous-run match in notebook.try_undo_restore rather than
  -- the single-entry match: before the fix the restored rows glued onto
  -- cell a (`a("a=1\nb=2\nc=3\nd=4"), e`) and b/c/d's ids were lost.
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  t.undo_break()
  vim.cmd("normal! V2jd")
  nb._flush_pending()
  t.eq(#nb.cells, 2)
  t.assert_consistent(nb, bufnr)

  vim.cmd("silent undo")
  nb._flush_pending()
  t.eq(#nb.cells, 5)
  t.eq(nb.cells[1].id, id_a)
  t.eq(nb.cells[2].id, id_b)
  t.eq(nb.cells[3].id, id_c)
  t.eq(nb.cells[4].id, id_d)
  t.eq(nb.cells[5].id, id_e)
  t.eq(nb.cells[1].code, "a = 1")
  t.eq(nb.cells[2].code, "b = 2")
  t.eq(nb.cells[3].code, "c = 3")
  t.eq(nb.cells[4].code, "d = 4")
  t.eq(nb.cells[5].code, "e = 5")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: undo-trash run matching does not splice unrelated deletes together (plan-refinement F1.1 finding #2)", function()
  local cell_mod = require("neo-marimo.cell")
  local nb = { cells = {}, cell_by_id = {} }

  -- Two unrelated single-cell deletes whose cached rows happen to land
  -- contiguously (2, then 3 = 2 + line_count 1). Each push_undo_trash call
  -- below omits batch_id, so notebook.push_undo_trash mints a fresh batch
  -- per call (see next_undo_batch) — modeling two separate edits rather
  -- than one compound delete that trashed both cells together.
  local cell_a = cell_mod.new({ code = "a = 1" }, 1)
  notebook.push_undo_trash(nb, cell_a, 2)
  local cell_b = cell_mod.new({ code = "b = 2" }, 2)
  notebook.push_undo_trash(nb, cell_b, 3)

  t.ok(nb._undo_trash[1].batch_id ~= nb._undo_trash[2].batch_id,
    "unrelated deletes must land in different batches")

  -- A later insertion at row 2 with delta 2 coincidentally matches the
  -- summed line_count of both entries (1 + 1) and their rows are
  -- contiguous — exactly the false-positive shape from finding #2. Without
  -- the batch check this would splice both cells back as one fabricated
  -- run instead of falling through to the generic sync path.
  local filtered = notebook.try_undo_restore(nb, { { start_row = 2, delta = 2 } })

  t.eq(#nb.cells, 0, "neither unrelated entry should be spliced back as a fake run")
  t.eq(#filtered, 1, "the unmatched change falls through to the generic sync path")
end)

t.case("editing: single-line delete inside a multi-line cell shrinks only it", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2\nbb = 22\nbbb = 222", "c = 3" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })  -- "bb = 22"
  vim.cmd("normal! dd")
  nb._flush_pending()
  t.eq(#nb.cells, 3)
  t.eq(nb.cells[2].code, "b = 2\nbbb = 222")
  t.eq(nb.cells[1].code, "a = 1")
  t.eq(nb.cells[3].code, "c = 3")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: move cell down swaps order and preserves code (7.5.6 follow-up)", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2\nprint(b)", "c = 3" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  actions.move_cell_down_at_cursor(bufnr, nb)
  t.eq(nb.cells[1].code, "b = 2\nprint(b)")
  t.eq(nb.cells[2].code, "a = 1")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    { "b = 2", "print(b)", "a = 1", "c = 3" })
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: move cell up swaps order and preserves code", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2\nprint(b)", "c = 3" })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })  -- "c = 3"
  actions.move_cell_up_at_cursor(bufnr, nb)
  t.eq(nb.cells[2].code, "c = 3")
  t.eq(nb.cells[3].code, "b = 2\nprint(b)")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: apply_remote_changes patches changed cells in place (7.5.4)", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2", "c = 3" })
  local ok = sync.apply_remote_changes(nb, {
    { code = "a = 1" },
    { code = "b = 200\nprint(b)" },
    { code = "c = 3" },
  })
  t.ok(ok, "apply_remote_changes failed")
  t.eq(nb.cells[2].code, "b = 200\nprint(b)")
  t.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    { "a = 1", "b = 200", "print(b)", "c = 3" })
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: apply_remote_changes no-op refreshes names only", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2" })
  local ok = sync.apply_remote_changes(nb, {
    { code = "a = 1", name = "setup" },
    { code = "b = 2" },
  })
  t.ok(ok, "apply_remote_changes failed")
  t.eq(nb.cells[1].name, "setup")
  t.eq(nb.cells[1].code, "a = 1")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: validate_offsets flags gaps and overlaps", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2" })
  -- Manufacture an overlap the way drift used to: hand-edit the integers.
  nb.cells[2].start_row = 0
  local ok, errors = notebook.validate_offsets(nb, bufnr)
  t.eq(ok, false)
  t.ok(#errors > 0, "expected at least one validation error")
end)

t.case("editing: stress sequence stays validator-clean", function()
  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2", "c = 3" })
  -- new cell, type into it
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  actions.new_cell_below(bufnr, nb)
  vim.cmd("normal! an = 10")
  nb._flush_pending()
  t.assert_consistent(nb, bufnr, "after new+type")

  -- move it down, then delete it
  actions.move_cell_down_at_cursor(bufnr, nb)
  t.assert_consistent(nb, bufnr, "after move down")
  t.undo_break()
  actions.delete_cell_at_cursor(bufnr, nb)
  t.assert_consistent(nb, bufnr, "after delete")

  -- undo the delete, edit the restored cell
  vim.cmd("silent undo")
  nb._flush_pending()
  t.assert_consistent(nb, bufnr, "after undo")

  t.eq(#nb.cells, 4)
end)

t.case("editing: jump_to_cell scrolls to a cell beyond the viewport (plan-refinement F2.2)", function()
  -- A full viewport-desync repro needs virt_lines-inflated output plus a
  -- real terminal redraw cycle, neither of which is reproducible headless.
  -- This pins the two things that ARE checkable: the cursor lands exactly
  -- on the target cell's first line even when that row starts off-screen,
  -- and the shared helper's `zz` actually ran (winline sits near vertical
  -- center rather than wherever nvim_win_set_cursor alone would have left
  -- it) — the same mechanics actions.lua / keymaps.lua now share via
  -- buffer.jump_to_cell instead of each keeping its own bare-cursor copy.
  local buffer = require("neo-marimo.buffer")
  local codes = {}
  for i = 1, 60 do
    table.insert(codes, "x" .. i .. " = " .. i)
  end
  local nb, bufnr = t.make_notebook(codes)

  local win_height = vim.api.nvim_win_get_height(0)
  t.ok(#nb.cells > win_height, "need more cells than the window can show at once")

  -- Start scrolled to the top so the last cell is off the initial viewport.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! zt")

  local target = nb.cells[#nb.cells]
  buffer.jump_to_cell(bufnr, target)

  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
  t.eq(cursor_row, target.start_row + 1, "cursor lands on the target cell's first line")

  local winline = vim.fn.winline()
  local mid = math.ceil(win_height / 2)
  t.ok(math.abs(winline - mid) <= 1,
    string.format("expected cursor near vertical center after zz (winline=%d, height=%d)",
      winline, win_height))
end)

t.case("editing: output mark renders before (inside) the border mark after an unrelated edit (F2.1)", function()
  -- F2.1: ns_border (bottom border) and ns_output (status/output) both
  -- anchor at the same row (cell.end_row). Verified empirically (cross-
  -- checked against actual rendered output via :TOhtml, and against
  -- nvim_buf_get_extmarks with ns_id = -1 — which returns same-position
  -- marks from every namespace in their actual render order): at a shared
  -- (row, col), a right_gravity = false mark always sorts/renders before a
  -- right_gravity = true one, *regardless* of which was created or
  -- recreated more recently, and regardless of `priority`. output.lua sets
  -- right_gravity = false on the output mark, so it should deterministically
  -- render before (i.e. inside the cell, above) ns_border's bottom mark
  -- (right_gravity defaults to true) — that ordering is not supposed to be
  -- an accident of creation timing.
  --
  -- This test isn't primarily probing that gravity rule (see output_spec.lua
  -- for the pinning behavior) — it's checking that refresh_after_mutation
  -- still re-renders cell 1's output after an edit to a *different* cell,
  -- so a stale or missing output mark doesn't silently drop out of the
  -- picture when render_all_borders repaints every border on every
  -- mutation.
  local hl = require("neo-marimo.highlights")
  local output = require("neo-marimo.output")
  -- Cell 1 spans two lines so its top border (virt_lines_above = true, at
  -- start_row) and bottom border (virt_lines_above = false, at end_row)
  -- land on different rows — otherwise a single-line cell's top and bottom
  -- border would both match end_row and pollute the row-0 probe below.
  local nb, bufnr = t.make_notebook({ "a = 1\nx = 9", "b = 2" })

  -- Give cell 1 an output and render it — this is the initial (now oldest)
  -- ns_output mark, anchored at cell 1's end_row.
  nb.cells[1].status = "idle"
  nb.cells[1]._has_run = true
  nb.cells[1].output = { mimetype = "text/plain", data = "hello" }
  output.render(bufnr, nb.cells[1])

  local function order_at(row)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })
    local out = {}
    for _, m in ipairs(marks) do
      -- Only the bottom-border variant (virt_lines_above = false) actually
      -- competes with the output mark for the same slot below `row`; the
      -- top border of the *next* cell can also land on this row but points
      -- its virt_lines upward, so it's excluded here.
      if m[2] == row and m[4].virt_lines_above == false then
        if m[4].ns_id == hl.ns_border then
          table.insert(out, "border")
        elseif m[4].ns_id == hl.ns_output then
          table.insert(out, "output")
        end
      end
    end
    return table.concat(out, ",")
  end

  -- An unrelated edit elsewhere in the buffer (cell 2, not cell 1) still
  -- goes through refresh_after_mutation, which reruns render_all_borders
  -- for the whole notebook — including cell 1's border.
  vim.api.nvim_win_set_cursor(0, { 3, #vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1] })
  vim.cmd("normal! A0")
  nb._flush_pending()

  -- Tests build notebooks without the full attach path, so
  -- nb._redraw_outputs is nil and refresh_after_mutation takes the direct
  -- fallback render loop instead of the debounced one — see buffer.lua.
  -- Either path must leave cell 1's output mark present and still ordered
  -- ahead of its border, i.e. it must not have been dropped or left stale
  -- by the unrelated edit to cell 2.
  t.eq(order_at(nb.cells[1].end_row), "output,border",
    "output still renders before (inside) the border at their shared anchor row")
  t.assert_consistent(nb, bufnr)
end)

t.case("editing: debounced nb._redraw_outputs (production wiring) re-anchors output after a mutation", function()
  -- The test above exercises refresh_after_mutation's *fallback* branch
  -- (nb._redraw_outputs nil, direct unthrottled loop). Nothing in the suite
  -- previously drove the *other* branch — the debounced closure init.lua
  -- actually installs in production — so a regression there (wrong wiring,
  -- wrong order against render_all_borders) could slip through with every
  -- test still green. Build that same debounce wiring here and prove the
  -- output mark still ends up pinned to the cell's live end_row once the
  -- timer fires.
  local hl = require("neo-marimo.highlights")
  local utils = require("neo-marimo.utils")
  local output = require("neo-marimo.output")

  local nb, bufnr = t.make_notebook({ "a = 1", "b = 2\nc = 2" })
  nb.cells[2].status = "idle"
  nb.cells[2]._has_run = true
  nb.cells[2].output = { mimetype = "text/plain", data = "hello" }

  -- Mirror init.lua's redraw_outputs closure exactly (buf-valid + in-a-window
  -- guards, then output.render_all through the same shared helper
  -- buffer.lua's fallback now also calls) and stash it the same way attach
  -- does, so refresh_after_mutation takes the debounced branch instead of
  -- the fallback. `calls` counts actual fires so the test can tell a
  -- debounced call apart from an extmark just riding the buffer edit under
  -- its own gravity (which would happen regardless of any render).
  local calls = 0
  nb._redraw_outputs = utils.debounce(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if #vim.fn.win_findbuf(bufnr) == 0 then return end
    calls = calls + 1
    output.render_all(bufnr, nb, nb.filepath)
  end, 200)

  -- Prime an initial render so there's a pre-existing mark to prove moved,
  -- not just created.
  nb._redraw_outputs()
  vim.wait(300, function() return calls == 1 end, 10)
  local before_end_row = nb.cells[2].end_row

  -- Grow cell 1 so cell 2's start/end rows shift down — the same kind of
  -- unrelated-edit mutation the fallback test above exercises, but this
  -- time through refresh_after_mutation's debounced branch. Cell 1 is a
  -- single line, so its only line is also its last — another `o`-at-a-
  -- boundary case (plan-refinement F3.1); mapped `normal` (no bang) so it
  -- grows cell 1 instead of donating the new line to cell 2.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal oz = 99")
  nb._flush_pending()
  t.ok(nb.cells[2].end_row > before_end_row,
    "cell 2 pushed down by the new line inserted above it")

  -- refresh_after_mutation only (re)armed the debounce timer synchronously —
  -- the render closure itself must not have fired yet.
  t.eq(calls, 1, "debounced redraw hasn't fired again yet — timer just (re)armed")

  vim.wait(500, function() return calls == 2 end, 10)
  t.eq(calls, 2, "debounced redraw fired once the 200ms timer elapsed")

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns_output, 0, -1, {})
  t.eq(#marks, 1, "one output mark after the debounced redraw")
  t.eq(marks[1][2], nb.cells[2].end_row,
    "output mark re-anchored to the cell's live end_row once the debounce fires")
end)

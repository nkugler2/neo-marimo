-- Integration tests for the stateful editing core: cell tracking via extmark
-- anchors (buffer.lua), structural actions (actions.lua), undo restore
-- (notebook.lua), and remote patching (sync.lua). These are the modules where
-- every historical data-corruption bug lived (see plan-phases-7-15.md §7.5);
-- each case here pins one of those scenarios so it can't silently regress.
--
-- The harness (helpers.make_notebook) builds a real marimo:// buffer with the
-- production change-tracking attached, then drives it like a user would:
-- nvim_buf_set_lines for typing, :normal! for motions, :undo for undo.
-- t.assert_consistent re-checks the save validator's invariants after every
-- mutation.

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
  vim.cmd("normal! obb = b")   -- open a new line inside cell 2
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
    vim.api.nvim_buf_del_extmark(bufnr, hl.ns_cell_anchor, cell.start_mark_id)
  end
  buffer.sync_cells_from_extmarks(bufnr, nb)

  t.eq(#nb.cells, 1, "one cell always survives a total anchor wipeout")
  t.eq(nb.cell_by_id[nb.cells[1].id], nb.cells[1], "cell_by_id stays consistent with the survivor")
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

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

local hl = require("neo-marimo.highlights")
local cell_mod = require("neo-marimo.cell")
local config = require("neo-marimo.config")

local M = {}

-- Place a fresh start-anchor extmark for `cell` at buffer row `row`. The
-- extmark sits in `ns_cell_anchor` (never wiped by border re-renders) with
-- right_gravity = true so an insertion at the boundary row pushes B down
-- and grows A. cell.start_mark_id stores the mark for later resolution.
function M.place_cell_anchor(bufnr, cell, row)
  if cell.start_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, hl.ns_cell_anchor, cell.start_mark_id)
    cell.start_mark_id = nil
  end
  cell.start_mark_id = vim.api.nvim_buf_set_extmark(bufnr, hl.ns_cell_anchor, row, 0, {
    right_gravity = true,
  })
end

-- Drop a cell's anchor. Used when the cell is removed (delete keymap, full
-- buffer rebuild before reload). Safe to call when no anchor is present.
function M.clear_cell_anchor(bufnr, cell)
  if cell.start_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, hl.ns_cell_anchor, cell.start_mark_id)
    cell.start_mark_id = nil
  end
end

-- Re-derive cell.start_row / cell.end_row / cell.code / cell.type from the
-- live extmark positions and the current buffer content. This is the only
-- code path that mutates cell.start_row/end_row after the initial create;
-- the old manual delta math (across actions.lua, keymaps.lua, sync.lua)
-- has been removed in favour of letting vim's own extmark machinery track
-- where each cell now lives.
--
-- Cells with no anchor yet (e.g. freshly minted, anchor not placed) are
-- left alone; the caller is expected to place an anchor before calling
-- sync.
function M.sync_cells_from_extmarks(bufnr, nb)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local total_lines = vim.api.nvim_buf_line_count(bufnr)

  -- First pass: read start_row from each anchor. If an anchor came back
  -- empty (vim removed it because its row range was wiped by a
  -- nvim_buf_set_lines), the cell is dead — drop it from the list before
  -- we try to compute end_row, otherwise we'd keep a phantom cell with a
  -- stale cached start_row.
  local i = 1
  while i <= #nb.cells do
    local cell = nb.cells[i]
    local dead = false
    if cell.start_mark_id then
      local mark = vim.api.nvim_buf_get_extmark_by_id(
        bufnr, hl.ns_cell_anchor, cell.start_mark_id, {}
      )
      if mark and mark[1] then
        cell.start_row = mark[1]
      else
        dead = true
      end
    end
    if dead then
      -- Push to undo trash before dropping. A `dd` on the only row of a
      -- 1-line cell removes the cell's anchor along with the line; the
      -- cell's id, options and code would be lost forever otherwise. With
      -- this push, the trash-matching path in notebook.try_undo_restore
      -- can splice the cell back when the user hits `u`. Mirrors the
      -- push that <leader>md does explicitly.
      nb._undo_trash = nb._undo_trash or {}
      table.insert(nb._undo_trash, 1, {
        id = cell.id,
        name = cell.name,
        code = cell.code,
        options = cell.options,
        status = cell.status,
        output = cell.output,
        console = cell.console,
        type = cell.type,
        start_row = cell.start_row,
        line_count = cell_mod.line_count(cell),
        trashed_at = vim.uv.hrtime() / 1e6,
      })
      while #nb._undo_trash > 5 do table.remove(nb._undo_trash) end

      nb.cell_by_id[cell.id] = nil
      table.remove(nb.cells, i)
    else
      i = i + 1
    end
  end
  for k, c in ipairs(nb.cells) do c.index = k end

  -- Sort cells by their current start_row so end_row computation (next
  -- cell's start - 1) works even if two cells momentarily share a row
  -- after a paste-then-immediate-something edge case. The reorder is
  -- only a defensive measure; in steady state the order is preserved
  -- by vim's gravity-respecting extmark movement.
  table.sort(nb.cells, function(a, b)
    if a.start_row == b.start_row then
      return (a.index or 0) < (b.index or 0)
    end
    return a.start_row < b.start_row
  end)
  for i, c in ipairs(nb.cells) do c.index = i end

  -- Second pass: end_row = next cell's start - 1; last cell ends at the
  -- buffer's last line. Cells that come out collapsed (end < start) here
  -- get stashed to undo trash before prune_phantoms kills them, so a
  -- subsequent `u` can splice them back. This handles the `dd` case
  -- where vim moves the anchor to a collision with the next cell rather
  -- than deleting it outright — the cell isn't "dead" (anchor is fine)
  -- but its claimed range collapsed.
  for i, cell in ipairs(nb.cells) do
    if i < #nb.cells then
      cell.end_row = nb.cells[i + 1].start_row - 1
    else
      cell.end_row = total_lines - 1
    end
    if cell.end_row < cell.start_row then
      -- Snapshot the cell as it stood before its rows were consumed.
      -- We use the original (pre-collapse) cell.code which still holds
      -- the deleted content from the last successful sync.
      local original_line_count = cell_mod.line_count(cell)
      -- Pick the row vim is about to reuse — it's the cell's start_row,
      -- which is what `u` will restore to.
      local restore_row = cell.start_row
      nb._undo_trash = nb._undo_trash or {}
      table.insert(nb._undo_trash, 1, {
        id = cell.id,
        name = cell.name,
        code = cell.code,
        options = cell.options,
        status = cell.status,
        output = cell.output,
        console = cell.console,
        type = cell.type,
        start_row = restore_row,
        line_count = original_line_count,
        trashed_at = vim.uv.hrtime() / 1e6,
      })
      while #nb._undo_trash > 5 do table.remove(nb._undo_trash) end

      cell.code = ""
    else
      local lines = vim.api.nvim_buf_get_lines(bufnr, cell.start_row, cell.end_row + 1, false)
      cell.code = table.concat(lines, "\n")
    end
    cell.type = cell_mod.detect_type(cell.code)
  end
end

-- Minimum usable border width. Below this we just stop drawing dashes rather
-- than producing wrapped/broken borders.
local MIN_BORDER_WIDTH = 40

-- Fallback width used when the buffer isn't displayed in any window yet
-- (e.g. during initial create before nvim_win_set_buf runs).
local FALLBACK_BORDER_WIDTH = 72

-- Compute the visible text width for a buffer, accounting for sign column,
-- number column, and fold column. Returns FALLBACK_BORDER_WIDTH if the buffer
-- isn't in any window.
function M.border_width(bufnr)
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    return FALLBACK_BORDER_WIDTH
  end
  local winid = wins[1]
  local total = vim.api.nvim_win_get_width(winid)
  local info = vim.fn.getwininfo(winid)[1]
  local textoff = (info and info.textoff) or 0
  local width = total - textoff
  if width < MIN_BORDER_WIDTH then width = MIN_BORDER_WIDTH end
  return width
end

-- Apply soft-wrap and related window-local options to a window showing the
-- notebook buffer. Idempotent; safe to call from BufWinEnter.
function M.apply_window_settings(winid)
  local ui = config.options.ui or {}
  local wrap_on = ui.wrap_cells ~= false
  vim.api.nvim_set_option_value("wrap", wrap_on, { win = winid })
  if wrap_on then
    vim.api.nvim_set_option_value("linebreak", true, { win = winid })
    vim.api.nvim_set_option_value("breakindent", true, { win = winid })
    vim.api.nvim_set_option_value("showbreak", "↳ ", { win = winid })
  end
end

-- Suppress on_bytes change tracking while running `fn`. Use this to wrap
-- any code-driven mutation (insert/delete/swap from actions or sync) so the
-- buffer-attach hook doesn't queue a delta that we've already accounted for
-- by hand. Uses a counter so nested calls are safe.
function M.with_suppressed_bytes(nb, fn)
  nb._suppress_on_bytes = (nb._suppress_on_bytes or 0) + 1
  local ok, err = pcall(fn)
  nb._suppress_on_bytes = nb._suppress_on_bytes - 1
  if not ok then error(err, 0) end
end

-- Build the top border virtual line for a cell.
-- Returns a list of {text, hl_group} chunks.
local function make_top_border(cell, border_hl, label_hl, opts, width)
  local style = opts.border_style or "rounded"

  if style == "none" then
    return {}
  end

  -- Cell-type labels. Nerd-font variants when ui.icons is on, plain ASCII
  -- otherwise. Glyphs: nf-fa-python, nf-md-language_markdown, nf-md-database,
  -- nf-md-meteor (marimo).
  local labels_icon = {
    python   = "  py ",
    markdown = "  md ",
    sql      = " 󰆼 sql ",
    marimo   = " 󰀘 mo ",
  }
  local labels_plain = {
    python   = " py ",
    markdown = " md ",
    sql      = " sql ",
    marimo   = " mo ",
  }
  local labels = (opts.icons == false) and labels_plain or labels_icon
  local type_label = labels[cell.type] or labels.python

  -- Build label: "[py] name" or just "[py]"
  local label = type_label
  if opts.show_cell_name and cell.name ~= "_" and cell.name ~= "" then
    label = label .. cell.name .. " "
  end
  if opts.show_cell_index then
    label = label .. "#" .. tostring(cell.index) .. " "
  end
  if cell_mod.is_disabled(cell) then
    label = label .. "disabled "
  end

  -- Pad label with dashes to fill the visible window width
  local corner_l = style == "rounded" and "╭" or "┌"
  local corner_r = style == "rounded" and "╮" or "┐"
  local dash = "─"

  local label_len = vim.fn.strwidth(label)
  local prefix_dashes = 1
  local suffix_len = width - 2 - prefix_dashes - label_len
  if suffix_len < 1 then suffix_len = 1 end
  local suffix_dashes = string.rep(dash, suffix_len)

  local chunks = {
    { corner_l,                            border_hl },
    { string.rep(dash, prefix_dashes),     border_hl },
    { label,                               label_hl },
    { suffix_dashes,                       border_hl },
    { corner_r,                            border_hl },
  }

  return chunks
end

-- Build the bottom border virtual line for a cell.
local function make_bot_border(border_hl, opts, width)
  local style = opts.border_style or "rounded"

  if style == "none" then
    return {}
  end

  local corner_l = style == "rounded" and "╰" or "└"
  local corner_r = style == "rounded" and "╯" or "┘"
  local dash = "─"

  local inner = width - 2
  if inner < 1 then inner = 1 end
  local dashes = string.rep(dash, inner)
  return {
    { corner_l, border_hl },
    { dashes,   border_hl },
    { corner_r, border_hl },
  }
end

-- Place extmarks for a single cell's borders.
local function render_cell_borders(bufnr, cell, width)
  local ui = config.options.ui or {}
  local border_hl, label_hl = hl.type_hls(cell.type)
  width = width or M.border_width(bufnr)

  -- Clear old border marks for this cell
  if cell.top_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, hl.ns_border, cell.top_mark_id)
  end
  if cell.bot_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, hl.ns_border, cell.bot_mark_id)
  end

  local top_chunks = make_top_border(cell, border_hl, label_hl, ui, width)
  local bot_chunks = make_bot_border(border_hl, ui, width)

  -- Top border: virtual line ABOVE start_row
  if #top_chunks > 0 then
    cell.top_mark_id = vim.api.nvim_buf_set_extmark(bufnr, hl.ns_border, cell.start_row, 0, {
      virt_lines = { top_chunks },
      virt_lines_above = true,
      priority = 100,
    })
  end

  -- Bottom border: virtual line AFTER end_row
  if #bot_chunks > 0 then
    cell.bot_mark_id = vim.api.nvim_buf_set_extmark(bufnr, hl.ns_border, cell.end_row, 0, {
      virt_lines = { bot_chunks },
      virt_lines_above = false,
      priority = 100,
    })
  end
end

-- Re-render borders for all cells. Call this after any structural change.
function M.render_all_borders(bufnr, nb)
  -- Clear entire border namespace first
  vim.api.nvim_buf_clear_namespace(bufnr, hl.ns_border, 0, -1)

  local width = M.border_width(bufnr)
  for _, cell in ipairs(nb.cells) do
    cell.top_mark_id = nil
    cell.bot_mark_id = nil
    render_cell_borders(bufnr, cell, width)
  end
end

-- Update borders for a single cell (e.g., after its row changed).
function M.render_cell_border(bufnr, cell)
  render_cell_borders(bufnr, cell)
end

-- Build the buffer lines from the notebook cells.
-- Returns a flat list of strings (no decorator boilerplate).
local function cells_to_lines(nb)
  local lines = {}
  for i, cell in ipairs(nb.cells) do
    local cell_lines = vim.split(cell.code, "\n", { plain = true })
    -- Ensure at least one line per cell (empty cells have one empty line)
    if #cell_lines == 0 then
      cell_lines = { "" }
    end
    local start_row = #lines  -- 0-indexed
    for _, line in ipairs(cell_lines) do
      table.insert(lines, line)
    end
    local end_row = #lines - 1  -- 0-indexed
    nb.cells[i].start_row = start_row
    nb.cells[i].end_row = end_row
  end
  return lines
end

-- Create the notebook view buffer from a notebook state.
-- Returns bufnr of the created buffer.
function M.create(nb, source_bufnr)
  local bufnr = vim.api.nvim_create_buf(false, true)

  -- Make it look and behave like a real file buffer.
  -- bufhidden = "hide" (not "wipe") so :MarimoToggle can swap the window to
  -- the plain .py and back without losing notebook state (cell outputs,
  -- statuses, debounced change queue). Explicit :bw still wipes and runs
  -- the BufWipeout cleanup below.
  vim.api.nvim_set_option_value("buftype", "acwrite", { buf = bufnr })
  vim.api.nvim_set_option_value("filetype", "python", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })

  -- Set a meaningful buffer name (shown in statusline)
  local fname = vim.fn.fnamemodify(nb.filepath, ":t")
  vim.api.nvim_buf_set_name(bufnr, "marimo://" .. nb.filepath)

  -- Populate buffer with cell content
  local lines = cells_to_lines(nb)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modified", false, { buf = bufnr })

  -- Anchor each cell with an extmark at its start_row. From this moment
  -- on, vim's extmark machinery tracks where the cell lives across every
  -- subsequent buffer mutation — the integer start_row/end_row become
  -- cached values refreshed by sync_cells_from_extmarks.
  for _, cell in ipairs(nb.cells) do
    M.place_cell_anchor(bufnr, cell, cell.start_row)
  end

  -- Render cell borders as virtual lines
  M.render_all_borders(bufnr, nb)

  nb.bufnr = bufnr

  return bufnr
end

-- Read current buffer lines and extract per-cell code.
-- Updates each cell's .code field and recomputes row offsets.
-- With Phase 7.5.6 anchors in place this dispatches to the extmark
-- resolver; without anchors (during the brief window of initial create)
-- it falls back to reading the cached start_row/end_row directly.
function M.sync_cells_from_buffer(nb)
  local bufnr = nb.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if nb.cells[1] and nb.cells[1].start_mark_id then
    M.sync_cells_from_extmarks(bufnr, nb)
    return true
  end

  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local total = #all_lines

  for i, cell in ipairs(nb.cells) do
    local s = cell.start_row + 1     -- 1-indexed for slice
    local e = cell.end_row + 1
    if s < 1 then s = 1 end
    if e > total then e = total end

    if s > e then
      cell.code = ""
    else
      local cell_lines = {}
      for row = s, e do
        table.insert(cell_lines, all_lines[row])
      end
      cell.code = table.concat(cell_lines, "\n")
    end

    cell.type = cell_mod.detect_type(cell.code)
  end

  return true
end

-- Find the 1-based cell index containing `row` (0-indexed). Falls back to
-- the last cell if `row` sits past the final cell (e.g. trailing-newline
-- inserts) and the first cell if it sits before the first.
local function cell_index_at_row(nb, row)
  for i, cell in ipairs(nb.cells) do
    if row >= cell.start_row and row <= cell.end_row then
      return i
    end
  end
  if #nb.cells == 0 then return nil end
  if row < nb.cells[1].start_row then return 1 end
  return #nb.cells
end

-- Resync cell offsets, prune phantoms, and re-render borders. Shared
-- between on_bytes_changed and the action paths (new/delete/move) so
-- every structural mutation goes through the same post-mutation
-- cleanup pipeline — sync → prune → sync → render.
function M.refresh_after_mutation(bufnr, nb)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  M.sync_cells_from_extmarks(bufnr, nb)
  -- Drop cells whose anchor collided with another (e.g. a swap that left
  -- two anchors at the same row) or whose range collapsed. Without this
  -- a phantom with end<start lingers and produces stacked borders.
  require("neo-marimo.notebook").prune_phantoms(nb)
  M.sync_cells_from_extmarks(bufnr, nb)
  M.render_all_borders(bufnr, nb)
end

-- Refresh cell offsets after vim has applied buffer changes. With cell
-- anchors in place (Phase 7.5.6), vim's own extmark machinery already
-- moved each cell's start_row to the correct position — we just need to
-- pull those positions back into cell.start_row/end_row and re-derive
-- cell.code from the buffer slice each cell now covers.
--
-- This replaces the old per-change delta math (insertion / cross-cell
-- delete cascade) entirely. The `changes` argument is kept for parity
-- with the previous signature but no longer used — extmarks need no
-- per-event reconciliation.
function M.on_bytes_changed(bufnr, nb, _changes)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  M.refresh_after_mutation(bufnr, nb)
  nb.dirty = true
end

return M

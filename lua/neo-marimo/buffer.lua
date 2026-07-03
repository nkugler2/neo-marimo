local hl = require("neo-marimo.highlights")
local cell_mod = require("neo-marimo.cell")
local config = require("neo-marimo.config")
local notebook = require("neo-marimo.notebook")
local utils = require("neo-marimo.utils")

local M = {}

-- Place (or move-in-place) `cell`'s anchor: a single RANGE extmark spanning
-- [start_row, end_row] in `ns_cell_anchor` (never wiped by border
-- re-renders). cell.anchor_mark_id stores the mark for later resolution.
--
-- plan-refinement F3.1 (cell-boundary anchor redesign). A single point mark
-- can't disambiguate the two boundary-insert intents: typing/`<CR>`/`O` at
-- a cell's first byte should stay IN that cell (needs right_gravity =
-- false on the start endpoint), while `A<CR>`/append at a cell's last byte
-- should GROW that cell (needs end_right_gravity = true on the end
-- endpoint). "End of A" and "start of B" are the same buffer position, so
-- one mark with two independently-gravitied endpoints makes them distinct
-- positions with distinct owners instead of re-aiming the same ambiguity.
--
-- A range mark over two point marks also buys: (1) nvim clamps end >= start
-- by construction, so a fully-deleted cell collapses to a zero-width point
-- (e.g. (1,0)-(1,0)) rather than an inverted range — the inversion class is
-- eliminated, not guarded against; (2) one id threads every lifecycle path
-- (undo trash, smart paste, moves, reload) and one
-- nvim_buf_get_extmark_by_id(..., {details=true}) call per cell in the sync
-- hot loop reads both endpoints at once.
--
-- Deliberately NOT invalidate = true — that would change the dead-anchor
-- semantics the F1.5 survivor-guard tests pin (a fully-collapsed cell must
-- still resolve to an empty-but-present range, not vanish outright).
--
-- Note: normal-mode `o` on a cell's LAST line is byte-identical to `O` on
-- the NEXT cell's first line — both splice "\n" at (next_row, 0), so
-- gravity alone cannot tell them apart. That case is handled by a
-- buffer-local `o` keymap (keymaps.lua), not by anchor placement.
--
-- end_row is defensively clamped to [start_row, line_count-1] since callers
-- occasionally compute it from arithmetic that could stray past either
-- bound (e.g. a shrinking neighbor).
function M.place_cell_anchors(bufnr, cell, start_row, end_row)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if end_row < start_row then end_row = start_row end
  if end_row > line_count - 1 then end_row = line_count - 1 end
  if start_row > end_row then start_row = end_row end

  local end_line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""

  cell.anchor_mark_id = vim.api.nvim_buf_set_extmark(bufnr, hl.ns_cell_anchor, start_row, 0, {
    id = cell.anchor_mark_id,   -- reuse in place when present: no delete/create churn
    end_row = end_row,
    end_col = #end_line,
    right_gravity = false,      -- start: an insert at this cell's first byte stays in it
    end_right_gravity = true,   -- end: an insert at this cell's last byte grows it
  })
end

-- Drop a cell's anchor. Used when the cell is removed (delete keymap, full
-- buffer rebuild before reload). Safe to call when no anchor is present.
function M.clear_cell_anchor(bufnr, cell)
  if cell.anchor_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, hl.ns_cell_anchor, cell.anchor_mark_id)
    cell.anchor_mark_id = nil
  end
end

-- Move the cursor to buffer row `row` (0-indexed, clamped to the last line)
-- in bufnr's current window, then center and force a redraw.
--
-- virt_lines-inflated cell outputs desync the viewport on a bare
-- nvim_win_set_cursor: the destination row can land outside the window's
-- painted region (or the window just doesn't repaint) until the next
-- manual keystroke, leaving the cursor apparently "stuck". `normal! zz` +
-- `redraw` forces the scroll immediately — first worked out for widget
-- focus-cycling (keymaps.lua) and now shared by every programmatic jump.
function M.jump_to_row(bufnr, row)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local target = math.min(row + 1, line_count) -- +1: nvim_win_set_cursor is 1-indexed
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd("normal! zz")
  vim.cmd("redraw")
end

-- Move the cursor to the start of `cell`. No-op if cell is nil (e.g. an
-- insert/delete that left no valid target). See jump_to_row for the
-- scroll/redraw rationale.
function M.jump_to_cell(bufnr, cell)
  if not cell then return end
  M.jump_to_row(bufnr, cell.start_row)
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

  -- Snapshot each cell's start_row as it stood coming into this sync, before
  -- the anchor-read pass below overwrites it. Needed for the undo-trash push:
  -- when several adjacent one-line cells are deleted in a single edit (e.g.
  -- `V2jd`), their point-anchors don't get invalidated — they all collapse
  -- onto the same post-delete row — so by the time we detect the collapse,
  -- cell.start_row has already been clobbered to that shared row for every
  -- cell in the run. Keyed by cell table identity since it must survive the
  -- upcoming removals/sort/reindex untouched.
  local orig_start_row = {}
  for _, c in ipairs(nb.cells) do orig_start_row[c] = c.start_row end

  -- All cells trashed by this sync call — whether by the dead-anchor sweep
  -- right below or the collapsed-range sweep further down — stem from the
  -- same buffer edit, so they share one batch id. try_undo_restore only
  -- grows a contiguous "run" match within a single batch; this stops it
  -- from gluing together two cells trashed by unrelated edits whose cached
  -- rows happen to land adjacently (plan-refinement F1.1 finding #2).
  local batch_id = notebook.next_undo_batch(nb)

  -- Guard against a single edit invalidating every cell's anchor at once
  -- (e.g. a `%d` or an equivalent whole-buffer replace). Without this, the
  -- loop below would drop every dead cell in turn and leave nb.cells == {}
  -- long before prune_phantoms ever runs — prune_phantoms' own last-survivor
  -- guard (below in notebook.lua) only protects *its* sweep over whatever
  -- cells are still standing when it runs, not this one. Pick the cell with
  -- the most surviving code (as of the last successful sync, since a dead
  -- anchor gives us no fresh row data to score with) as the designated
  -- survivor and never drop it here, even if its anchor comes back dead —
  -- mirrors prune_phantoms' survivor-selection approach one function down.
  local survivor_id = nb.cells[1] and nb.cells[1].id
  local survivor_score = nb.cells[1] and cell_mod.line_count(nb.cells[1]) or 0
  for idx = 2, #nb.cells do
    local c = nb.cells[idx]
    local score = cell_mod.line_count(c)
    if score > survivor_score then
      survivor_score = score
      survivor_id = c.id
    end
  end

  -- Pass 1: read each live cell's anchor geometry (both endpoints — the
  -- anchor is now a single RANGE extmark, plan-refinement F3.1) into `raw`,
  -- keyed by cell table identity so it threads through the sort/resolve
  -- passes below without re-reading the extmark. If an anchor came back
  -- empty (vim removed it because its row range was wiped by a
  -- nvim_buf_set_lines), the cell is dead — drop it from the list before we
  -- try to resolve spans, otherwise we'd keep a phantom cell with stale
  -- cached rows.
  local raw = {}
  local i = 1
  while i <= #nb.cells do
    local cell = nb.cells[i]
    local dead = false
    if cell.anchor_mark_id then
      local mark = vim.api.nvim_buf_get_extmark_by_id(
        bufnr, hl.ns_cell_anchor, cell.anchor_mark_id, { details = true }
      )
      if mark and mark[1] then
        local details = mark[3]
        local r = {
          srow = mark[1], scol = mark[2],
          erow = details.end_row, ecol = details.end_col,
        }
        -- A whole-line replace/<CR> can leave the end endpoint at
        -- (row+1, 0) — a "past the trailing newline" sentinel (possibly one
        -- past the last buffer row). When that happens the cell's real
        -- content ends one row earlier.
        r.content_end = (r.erow > r.srow and r.ecol == 0) and (r.erow - 1) or r.erow
        -- A zero-width range (start == end exactly) means the cell's bytes
        -- are gone — nvim clamps a range extmark so end can never invert
        -- past start, so a fully-deleted cell collapses to a point instead
        -- of an inverted range. See pass 2 for why this matters.
        r.zero_width = (r.srow == r.erow and r.scol == r.ecol)
        raw[cell] = r
        cell.start_row = r.srow
      else
        dead = true
      end
    else
      -- Freshly minted cell, anchor not placed yet (see the docstring
      -- above M.sync_cells_from_extmarks): fall back to its cached rows
      -- and skip the anchor re-normalization in pass 3 below.
      raw[cell] = {
        srow = cell.start_row, erow = cell.end_row,
        content_end = cell.end_row, zero_width = false,
      }
    end
    if dead and cell.id == survivor_id then
      -- Designated survivor: never drop it, even though its own anchor is
      -- gone. It keeps whatever start_row/code it had cached before this
      -- sync; the resolve pass below and validate_offsets will surface any
      -- resulting collapse or misplacement, but the notebook is never left
      -- with zero cells. Its anchor came back empty, so — like the
      -- no-anchor-yet branch above — fall back to its cached rows; pass 3
      -- will re-place a fresh anchor at the resolved span (place_cell_anchors
      -- happily reuses a stale/now-nonexistent id).
      dead = false
      raw[cell] = {
        srow = cell.start_row, erow = cell.end_row,
        content_end = cell.end_row, zero_width = false,
      }
    end
    if dead then
      -- Push to undo trash before dropping. A `dd` on the only row of a
      -- 1-line cell removes the cell's anchor along with the line; the
      -- cell's id, options and code would be lost forever otherwise. With
      -- this push, the trash-matching path in notebook.try_undo_restore
      -- can splice the cell back when the user hits `u`. Mirrors the
      -- push that the delete-cell action does explicitly.
      notebook.push_undo_trash(nb, cell, orig_start_row[cell], batch_id)

      nb.cell_by_id[cell.id] = nil
      table.remove(nb.cells, i)
    else
      i = i + 1
    end
  end
  for k, c in ipairs(nb.cells) do c.index = k end

  -- Pass 2: sort by (start_row, zero-width-last, index). A zero-width range
  -- means the cell's bytes are gone (e.g. `dd`'d down to nothing); when it
  -- contends for a row with a content-bearing cell at the same start (a
  -- phantom vs. the cell that inherited its row), the phantom must lose the
  -- row and fall into the collapsed path in pass 3, rather than stealing
  -- the row out from under the cell that actually owns the content. Ties
  -- among otherwise-equal cells keep today's index rule — the reorder is
  -- only a defensive measure; in steady state order is preserved by vim's
  -- gravity-respecting extmark movement.
  table.sort(nb.cells, function(a, b)
    local ra, rb = raw[a], raw[b]
    if ra.srow ~= rb.srow then return ra.srow < rb.srow end
    if ra.zero_width ~= rb.zero_width then return not ra.zero_width end
    return (a.index or 0) < (b.index or 0)
  end)
  for k, c in ipairs(nb.cells) do c.index = k end

  -- Pass 3: resolve each cell's span from its own raw geometry (no longer
  -- derived from the next cell's start — each cell's end is read directly
  -- off its own anchor's end endpoint), clamped forward past whatever an
  -- earlier cell's end anchor already claimed, and trash any cell whose
  -- resolved span collapses.
  local next_free = 0
  for k, cell in ipairs(nb.cells) do
    local r = raw[cell]
    -- Clamp forward past rows an earlier cell already claimed. Needed
    -- because a whole-line nvim_buf_set_lines replacement (gcc, smart
    -- paste, apply_remote_changes, cell swap) pulls the FOLLOWING cell's
    -- gravity-false start endpoint back onto the replaced region's start —
    -- without this clamp two cells would both claim the same row.
    local s = math.max(r.srow, next_free)
    local e
    if k == #nb.cells then
      e = total_lines - 1 -- last cell owns to buffer end (today's rule)
    else
      -- Gap rows (rows between this cell's own content end and the next
      -- cell's raw start) go to the earlier cell — the old derived
      -- end_row semantics, preserved even though end_row is now primarily
      -- read off this cell's own anchor.
      e = math.max(r.content_end, raw[nb.cells[k + 1]].srow - 1)
    end
    if e > total_lines - 1 then e = total_lines - 1 end

    if s > total_lines - 1 or e < s then
      -- Collapsed: EXACT existing handling. Snapshot the cell as it stood
      -- before its rows were consumed — the pre-collapse cell.code still
      -- holds the deleted content from the last successful sync;
      -- orig_start_row[cell] is the cell's true original row (see the
      -- snapshot comment above), which is where `u` restores it — cell's
      -- resolved start_row itself may have already collided with a sibling
      -- collapsed in the same edit. This is the `dd` case where vim moves
      -- the anchor to a collision with the next cell rather than deleting
      -- it outright — the cell isn't "dead" (anchor is fine) but its
      -- claimed range collapsed.
      cell.start_row, cell.end_row = s, s - 1
      notebook.push_undo_trash(nb, cell, orig_start_row[cell], batch_id)

      cell.code = ""
    else
      cell.start_row, cell.end_row = s, e
      next_free = e + 1
      local lines = vim.api.nvim_buf_get_lines(bufnr, s, e + 1, false)
      cell.code = table.concat(lines, "\n")

      -- Re-normalize this cell's anchor to its resolved canonical span.
      -- Whole-line replacements pull the NEXT cell's gravity-false start
      -- endpoint back onto the replaced region's start, and <CR>/replaces
      -- can leave end endpoints at past-end (row+1, 0) sentinels. Left in
      -- place, those skewed marks compound on the next edit; re-placing
      -- every live cell's mark at its resolved canonical span makes each
      -- sync self-healing. Extmark moves fire no on_bytes, so this is safe
      -- both inside and outside with_suppressed_bytes.
      if cell.anchor_mark_id then
        M.place_cell_anchors(bufnr, cell, s, e)
      end
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

  -- Anchor each cell with a [start_row, end_row] range extmark. From this
  -- moment on, vim's extmark machinery tracks where the cell lives across
  -- every subsequent buffer mutation — the integer start_row/end_row become
  -- cached values refreshed by sync_cells_from_extmarks.
  for _, cell in ipairs(nb.cells) do
    M.place_cell_anchors(bufnr, cell, cell.start_row, cell.end_row)
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

  if nb.cells[1] and nb.cells[1].anchor_mark_id then
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
  notebook.prune_phantoms(nb)
  M.sync_cells_from_extmarks(bufnr, nb)
  M.render_all_borders(bufnr, nb)

  -- Re-render outputs after borders on every mutation, not just resize.
  -- render_all_borders above just recreated every border mark at
  -- cell.end_row; the output mark (also at cell.end_row, see output.lua)
  -- needs re-rendering too, for a reason that's about *content*, not
  -- stacking order: with right_gravity = false, the output mark's render
  -- position relative to the border's bottom mark is already deterministic
  -- (verified: a right_gravity = false mark always sorts/renders before a
  -- right_gravity = true one at the same anchor, regardless of creation
  -- order — priority doesn't enter into it either). What isn't automatic
  -- is the *content*: an edit anywhere in the notebook can shift
  -- cell.end_row for cells below it, and the output virt_lines themselves
  -- may need rewrapping (window width) or just haven't been touched since
  -- the buffer changed underneath them. Re-rendering here keeps the output
  -- pinned to the live end_row and its content current, not stale.
  -- Goes through the same debounced closure init.lua wires up for
  -- WinResized so a burst of keystrokes doesn't re-run the (comparatively
  -- expensive) output tree walk on every single mutation.
  if nb._redraw_outputs then
    nb._redraw_outputs()
  else
    -- Tests build notebooks without the full attach path (no init.lua
    -- autocmds), so nb._redraw_outputs may not exist. Fall back to a
    -- direct, unthrottled render loop rather than silently doing nothing —
    -- this path is not hit in production, where attach always sets
    -- nb._redraw_outputs.
    require("neo-marimo.output").render_all(bufnr, nb, nb.filepath)
  end
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

-- Wire on_bytes change tracking onto a notebook buffer. on_bytes gives us
-- the exact row where each change happened (start_row + line-count delta),
-- so deltas are attributed to the cell that actually changed — not the cell
-- under the cursor. Pressing Enter mid-cell used to misroute the delta to
-- the next cell because the cursor moved before the autocmd fired; on_bytes
-- fixes that at the source.
--
-- Flushes are debounced 300ms, but action paths (delete cell, insert cell,
-- run cell, …) call nb._flush_pending() synchronously before reading
-- cell.start_row/end_row. Without that gate, typing then immediately
-- triggering an action would read stale offsets and either crash
-- (out-of-range extmarks) or corrupt cell boundaries.
--
-- Lives here (not init.lua) so the headless test harness attaches the exact
-- wiring production uses.
function M.attach_change_tracking(bufnr, nb)
  local pending_changes = {}
  nb._flush_pending = function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      pending_changes = {}
      return
    end
    if #pending_changes == 0 then return end
    local changes = pending_changes
    pending_changes = {}

    -- Catch `u` after a cell delete: the trashed cell snapshot is matched
    -- against the +N insertion vim just replayed. Restoring sets nb.cells
    -- back to its pre-delete shape; any change consumed here is dropped
    -- from the batch so on_bytes_changed doesn't also try to absorb it.
    local pre_count = #changes
    changes = notebook.try_undo_restore(nb, changes)
    local restored = pre_count > #changes

    if #changes > 0 then
      M.on_bytes_changed(bufnr, nb, changes)
    elseif restored then
      -- We only restored cells; no remaining deltas to apply. Still need
      -- to redraw borders so the brought-back cell paints.
      M.render_all_borders(bufnr, nb)
    end
  end
  local flush_changes = utils.debounce(nb._flush_pending, 300)

  vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(_, bnr, _changedtick,
                        start_row, _start_col, _start_byte,
                        old_end_row, _old_end_col, _old_end_byte,
                        new_end_row, _new_end_col, _new_end_byte)
      if bnr ~= bufnr then return true end  -- detach if buffer mismatch
      -- Skip changes driven by our own actions (cell insert/delete/swap,
      -- reload). Those code paths update cell offsets by hand, so letting
      -- on_bytes also queue a delta would double-count and corrupt the
      -- offsets ~300ms later when the debounce fires.
      if (nb._suppress_on_bytes or 0) > 0 then return end
      local delta = new_end_row - old_end_row
      table.insert(pending_changes, { start_row = start_row, delta = delta })
      flush_changes()
    end,
  })
end

return M

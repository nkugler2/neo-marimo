local buffer = require("neo-marimo.buffer")
local parser = require("neo-marimo.parser")
local utils = require("neo-marimo.utils")
local config = require("neo-marimo.config")
local server = require("neo-marimo.server")

local M = {}

-- Suppression window (ms) for the file watcher around our own writes.
-- After we writefile() the .py we expect at least one fs_event; we don't
-- want it to cycle back through reload_from_file and clobber the cursor.
-- 750ms covers atomic-save + curl-roundtrip on slow disks.
local SAVE_SUPPRESS_MS = 750

-- Mark the notebook as "we just wrote this; ignore the next watcher
-- event". Cleared on a timer so the suppression doesn't outlive the
-- write that caused it.
local function suppress_watcher(nb)
  nb._suppress_watcher = (nb._suppress_watcher or 0) + 1
  vim.defer_fn(function()
    nb._suppress_watcher = math.max(0, (nb._suppress_watcher or 1) - 1)
  end, SAVE_SUPPRESS_MS)
end

-- True if a recent in-nvim write means we should ignore the next
-- watcher event. Public so the watcher callback can check it without
-- reaching into sync internals.
function M.is_writing(nb)
  return (nb._suppress_watcher or 0) > 0
end

-- Write the notebook state back to the .py file on disk.
-- Called from BufWriteCmd.
function M.write_to_file(nb)
  local bufnr = nb.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    utils.error("Cannot write: notebook buffer is no longer valid.")
    return false
  end

  -- Sync cell code from buffer content
  buffer.sync_cells_from_buffer(nb)

  -- Build cell list for the bridge
  local cells = {}
  for _, cell in ipairs(nb.cells) do
    table.insert(cells, {
      name = cell.name,
      code = cell.code,
      options = cell.options or {},
    })
  end

  -- Call Python bridge to generate .py source. We arm the watcher
  -- suppression before writefile so the inevitable fs_event lands inside
  -- the window — otherwise the watcher would round-trip the change
  -- back through reload_from_file and clobber the cursor.
  suppress_watcher(nb)
  local ok, err = pcall(function()
    local py_source = parser.generate_py(cells, nb.filepath, config.options.python_path)
    local lines = vim.split(py_source, "\n", { plain = true })
    -- Remove trailing empty line if writefile would add one
    if lines[#lines] == "" then
      table.remove(lines)
    end
    vim.fn.writefile(lines, nb.filepath)
  end)

  if not ok then
    utils.error("Failed to write notebook: " .. tostring(err))
    return false
  end

  -- Mark buffer as unmodified
  vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
  nb.dirty = false

  -- Push to the running marimo server so its in-memory view matches
  -- disk immediately. Without this the server lags ~1s while its own
  -- file watcher catches up, which causes browser ↔ nvim drift when
  -- both editors are in play. Best-effort: if the server isn't
  -- running, or push_on_save is disabled, skip silently.
  local srv_cfg = config.options.server or {}
  if srv_cfg.push_on_save ~= false and server.is_running(nb.filepath) then
    pcall(server.save_cells, nb.filepath, nb.cells)
  end

  vim.notify("[neo-marimo] Saved " .. vim.fn.fnamemodify(nb.filepath, ":t"), vim.log.levels.INFO)
  return true
end

-- Re-read the .py file and rebuild the notebook buffer.
-- Used when the file changes externally.
function M.reload_from_file(nb)
  local bufnr = nb.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local ok, data = pcall(parser.parse_file, nb.filepath, config.options.python_path)
  if not ok then
    utils.warn("Failed to reload notebook: " .. tostring(data))
    return false
  end

  -- Rebuild cells
  local cell_mod = require("neo-marimo.cell")
  nb.cells = {}
  nb.cell_by_id = {}
  for i, raw in ipairs(data.cells or {}) do
    local c = cell_mod.new(raw, i)
    table.insert(nb.cells, c)
    nb.cell_by_id[c.id] = c
  end

  -- Rewrite buffer content
  local lines = {}
  for i, cell in ipairs(nb.cells) do
    local cell_lines = vim.split(cell.code, "\n", { plain = true })
    if #cell_lines == 0 then cell_lines = { "" } end
    local start_row = #lines
    for _, l in ipairs(cell_lines) do
      table.insert(lines, l)
    end
    cell.start_row = start_row
    cell.end_row = #lines - 1
  end

  buffer.with_suppressed_bytes(nb, function()
    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modified", false, { buf = bufnr })

    buffer.render_all_borders(bufnr, nb)
  end)
  nb.dirty = false
  return true
end

-- Apply external cell changes to the notebook in-place.
--
-- `new_cells_data` is an ordered list of {code, name, options} produced
-- either by re-parsing the .py from disk (file-watcher path) or by
-- merging a marimo `update-cell-codes` payload with the existing cell
-- list (WS path).
--
-- The fast path replaces only the changed cells via nvim_buf_set_lines,
-- preserving the cursor position when possible. When the structure
-- changes (cells added/removed), we fall back to reload_from_file which
-- rebuilds the whole buffer.
--
-- Returns true if the buffer was patched (or no change was needed),
-- false on failure.
function M.apply_remote_changes(nb, new_cells_data)
  local bufnr = nb.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if type(new_cells_data) ~= "table" then return false end

  -- Structural change → full reload. Cells don't have stable IDs across
  -- parse calls (the bridge mints fresh IDs each time), so we can't
  -- diff by ID; we use position equality of cell count as a proxy.
  if #new_cells_data ~= #nb.cells then
    return M.reload_from_file(nb)
  end

  -- Make sure our in-memory cell offsets match the buffer. The user may
  -- have typed since we last wrote — sync_cells_from_buffer leaves
  -- offsets alone (they're maintained by on_bytes) but refreshes .code,
  -- which is what we compare against.
  buffer.sync_cells_from_buffer(nb)

  -- No-op fast path: every cell matches. This is common when an
  -- update-cell-codes arrives for changes we ourselves originated, or
  -- when the file-watcher fires for an unrelated touch.
  local any_changed = false
  for i, new in ipairs(new_cells_data) do
    if (new.code or "") ~= nb.cells[i].code then
      any_changed = true
      break
    end
  end
  if not any_changed then
    -- Even on no-op, refresh name/options in case those changed.
    for i, new in ipairs(new_cells_data) do
      if new.name then nb.cells[i].name = new.name end
      if new.options then nb.cells[i].options = new.options end
    end
    buffer.render_all_borders(bufnr, nb)
    return true
  end

  -- Capture cursor so we can restore it post-replace. We only restore
  -- when the notebook buffer is actually the active buffer in the
  -- current window — otherwise we'd move the cursor in some other
  -- window the user is looking at.
  local cur_win = vim.api.nvim_get_current_win()
  local same_buf = (vim.api.nvim_win_get_buf(cur_win) == bufnr)
  local cur_row, cur_col
  if same_buf then
    local pos = vim.api.nvim_win_get_cursor(cur_win)
    cur_row, cur_col = pos[1], pos[2]
  end

  local cell_mod = require("neo-marimo.cell")

  buffer.with_suppressed_bytes(nb, function()
    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })

    -- Walk front-to-back. Each replacement shifts subsequent cells by
    -- (#new_lines - #old_lines); we propagate the delta forward as we
    -- go so each cell's start_row/end_row stays accurate for the next
    -- nvim_buf_set_lines call.
    for i, new in ipairs(new_cells_data) do
      local cell = nb.cells[i]
      local new_code = new.code or ""
      if new_code ~= cell.code then
        local new_lines = vim.split(new_code, "\n", { plain = true })
        if #new_lines == 0 then new_lines = { "" } end

        vim.api.nvim_buf_set_lines(
          bufnr, cell.start_row, cell.end_row + 1, false, new_lines
        )

        local old_count = cell.end_row - cell.start_row + 1
        local delta = #new_lines - old_count

        cell.code = new_code
        if new.name then cell.name = new.name end
        if new.options then cell.options = new.options end
        cell.type = cell_mod.detect_type(cell.code)
        cell.end_row = cell.start_row + #new_lines - 1

        for j = i + 1, #nb.cells do
          nb.cells[j].start_row = nb.cells[j].start_row + delta
          nb.cells[j].end_row = nb.cells[j].end_row + delta
        end
      end
    end

    vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
    buffer.render_all_borders(bufnr, nb)
  end)

  -- Best-effort cursor restore. If the line moved past the new buffer
  -- end (because a cell shrank), clamp to the last line.
  if same_buf and cur_row then
    local lc = vim.api.nvim_buf_line_count(bufnr)
    if cur_row > lc then cur_row = lc end
    pcall(vim.api.nvim_win_set_cursor, cur_win, { cur_row, cur_col })
  end

  nb.dirty = false
  return true
end

return M

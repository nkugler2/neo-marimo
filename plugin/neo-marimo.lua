-- neo-marimo plugin entry point
-- This file is sourced automatically when the plugin is on the runtimepath.

-- Add the plugin root to rtp so TreeSitter can find our injection queries
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
if not vim.tbl_contains(vim.opt.rtp:get(), plugin_root) then
  vim.opt.rtp:prepend(plugin_root)
end

-- Automatically detect and attach to marimo notebooks when opened
vim.api.nvim_create_autocmd("BufReadPost", {
  pattern = "*.py",
  group = vim.api.nvim_create_augroup("NeoMarimo", { clear = true }),
  callback = function(ev)
    -- Defer slightly so filetype detection runs first
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(ev.buf) then return end

      local marimo = require("neo-marimo")

      -- Only process if not already a notebook buffer
      local bufname = vim.api.nvim_buf_get_name(ev.buf)
      if bufname:match("^marimo://") then return end

      -- :MarimoToggle off explicitly loads the underlying .py buffer; skip
      -- auto-attach so we don't immediately bounce back into notebook view.
      if marimo._suppress_attach then return end

      if marimo.is_marimo_notebook(ev.buf) then
        -- Auto-setup with defaults if user hasn't called setup()
        if not require("neo-marimo.config").options.python_path then
          marimo.setup({})
        end
        marimo.attach(ev.buf)
      end
    end)
  end,
})

-- User commands
vim.api.nvim_create_user_command("MarimoOpen", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  local marimo_cmd = require("neo-marimo.config").options.marimo_cmd or "marimo"
  vim.fn.jobstart({ marimo_cmd, "edit", nb.filepath }, { detach = true })
  vim.notify("[neo-marimo] Opening " .. vim.fn.fnamemodify(nb.filepath, ":t") .. " in browser...", vim.log.levels.INFO)
end, { desc = "Open current marimo notebook in browser" })

vim.api.nvim_create_user_command("MarimoStop", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  require("neo-marimo.server").stop(nb.filepath)
  require("neo-marimo.output").clear_all(nb.bufnr)
end, { desc = "Stop the marimo server for the current notebook" })

vim.api.nvim_create_user_command("MarimoReclaim", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  require("neo-marimo.server").reclaim_ws(nb.filepath)
end, { desc = "Reclaim the WebSocket connection from the browser" })

vim.api.nvim_create_user_command("MarimoReload", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  require("neo-marimo.sync").reload_from_file(nb)
  vim.notify("[neo-marimo] Reloaded from disk", vim.log.levels.INFO)
end, { desc = "Reload marimo notebook from disk" })

vim.api.nvim_create_user_command("MarimoAttach", function()
  -- Manually attach to current buffer (in case auto-detection missed it)
  local bufnr = vim.api.nvim_get_current_buf()
  require("neo-marimo").attach(bufnr)
end, { desc = "Attach neo-marimo to current Python buffer" })

vim.api.nvim_create_user_command("MarimoToggle", function()
  -- Swap the current window between notebook view and the underlying .py.
  -- The notebook buffer stays loaded in the background, so toggling does
  -- not stop the marimo server (unless server.stop_on_close is enabled
  -- and the buffer is later :bw'd).
  require("neo-marimo").toggle()
end, { desc = "Toggle between marimo notebook view and the underlying .py" })

-- Format a "started N {s,m,h} ago" stamp without bringing in any deps.
local function format_age(seconds)
  if not seconds or seconds < 0 then return "?" end
  if seconds < 60 then return seconds .. "s" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  return math.floor(seconds / 3600) .. "h"
end

-- Render the server list inside a floating scratch buffer with one server
-- per row and a <CR> jump-to-notebook keymap. Replaces the old vim.notify
-- dump so callers can act on the rows, not just read them.
local function open_server_list_window()
  local server = require("neo-marimo.server")
  local marimo = require("neo-marimo")
  local statusline = require("neo-marimo.statusline")

  local managed = statusline.servers()  -- enriched with cell_count
  local procs = server.list_system_marimo_processes()

  -- row_actions: 1-indexed line -> { kind = "switch", filepath = ... }
  -- Only managed-server lines are actionable; header/footer rows are inert.
  local lines = {}
  local row_actions = {}

  table.insert(lines, "neo-marimo servers")
  table.insert(lines, string.rep("─", 60))
  table.insert(lines, "Managed (" .. #managed .. "):")
  if #managed == 0 then
    table.insert(lines, "  (none — open a notebook and press <leader>mo)")
  else
    for _, s in ipairs(managed) do
      local fname = vim.fn.fnamemodify(s.filepath, ":t")
      local ws = s.ws_connected and "✓" or "✗"
      local age = s.started_at and (os.time() - s.started_at) or 0
      table.insert(lines, string.format(
        "  [ws %s] %-30s port=%d  cells=%d  age=%s",
        ws, fname, s.port, s.cell_count or 0, format_age(age)
      ))
      row_actions[#lines] = { kind = "switch", filepath = s.filepath }
    end
  end

  table.insert(lines, "")
  table.insert(lines, "System marimo processes:")
  if #procs == 0 then
    table.insert(lines, "  (none)")
  else
    for _, p in ipairs(procs) do
      local orphan = (p.ppid == 1) and "  [ORPHAN]" or ""
      table.insert(lines, string.format("  pid=%d  ppid=%s%s",
        p.pid, tostring(p.ppid), orphan))
      table.insert(lines, "    " .. p.cmd)
    end
  end

  table.insert(lines, "")
  table.insert(lines, "<CR> switch to notebook · K kill all marimo · q/<Esc> close")

  -- Size the window to the longest line (capped to 90% of the editor width).
  local content_width = 0
  for _, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l)
    if w > content_width then content_width = w end
  end
  local width = math.max(50, math.min(content_width + 4, math.floor(vim.o.columns * 0.9)))
  local height = math.min(#lines + 1, math.floor(vim.o.lines * 0.8))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "marimo-server-list", { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative   = "editor",
    width      = width,
    height     = height,
    col        = math.floor((vim.o.columns - width) / 2),
    row        = math.floor((vim.o.lines - height) / 2),
    style      = "minimal",
    border     = "rounded",
    title      = " marimo servers ",
    title_pos  = "center",
  })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  -- Park the cursor on the first actionable row so <CR> Just Works.
  for line_no, _ in pairs(row_actions) do
    vim.api.nvim_win_set_cursor(win, { line_no, 0 })
    break
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function open_kmap(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, {
      buffer = buf, silent = true, noremap = true, desc = desc,
    })
  end

  open_kmap("<CR>", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local action = row_actions[line]
    if not action then return end
    if action.kind == "switch" then
      close()
      local nb = marimo.attached_for(action.filepath)
      if nb and nb.bufnr
          and vim.api.nvim_buf_is_valid(nb.bufnr)
          and vim.api.nvim_buf_is_loaded(nb.bufnr) then
        vim.api.nvim_win_set_buf(0, nb.bufnr)
      else
        -- Fall back to a normal edit; auto-attach will pick it up.
        vim.cmd("edit " .. vim.fn.fnameescape(action.filepath))
      end
    end
  end, "Switch to selected marimo notebook")

  open_kmap("q",     close, "Close server list")
  open_kmap("<Esc>", close, "Close server list")

  open_kmap("K", function()
    close()
    local n = server.kill_all_system_marimo()
    vim.notify("[neo-marimo] Killed " .. n .. " marimo process(es).", vim.log.levels.INFO)
  end, "Kill every marimo process on the system")
end

vim.api.nvim_create_user_command("MarimoServerList", function()
  open_server_list_window()
end, { desc = "Show managed marimo servers and orphan processes (interactive)" })

-- Validate that nb.cells[].start_row/end_row form a contiguous, non-overlapping
-- cover of the buffer. When borders stack ("py #N" labels on the same row) or
-- multiple "✓ ran" indicators appear on the same cell, run this to confirm
-- whether the notebook's row bookkeeping has drifted from the buffer.
vim.api.nvim_create_user_command("MarimoCheck", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  local ok, errors = require("neo-marimo.notebook").validate_offsets(nb, nb.bufnr)
  if ok then
    vim.notify(string.format(
      "[neo-marimo] cell offsets OK (%d cells, %d buffer lines)",
      #nb.cells, vim.api.nvim_buf_line_count(nb.bufnr)),
      vim.log.levels.INFO)
    return
  end
  local lines = { string.format("[neo-marimo] offset corruption (%d issue(s)):", #errors) }
  for _, e in ipairs(errors) do
    table.insert(lines, "  - " .. e)
  end
  table.insert(lines, "")
  table.insert(lines, "Cells:")
  for i, c in ipairs(nb.cells) do
    table.insert(lines, string.format(
      "  [%d] id=%s  start_row=%d  end_row=%d  code_lines=%d",
      i, tostring(c.id), c.start_row, c.end_row,
      require("neo-marimo.cell").line_count(c)))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN)
end, { desc = "Validate notebook cell row offsets against buffer state" })

vim.api.nvim_create_user_command("MarimoKillAll", function()
  local server = require("neo-marimo.server")
  local n = server.kill_all_system_marimo()
  vim.notify("[neo-marimo] Killed " .. n .. " marimo process(es).", vim.log.levels.INFO)
end, { desc = "Force-kill all marimo edit processes on the system" })

-- Send a hand-crafted ping frame to the WS. The marimo server's WS
-- receive loop only uses incoming frames for disconnect detection (so it
-- won't respond), but with :MarimoWsDebug logging on we can confirm the
-- pipe didn't die or close the connection. Useful for verifying the
-- ws_client.py stdin → WS round-trip after a code change.
vim.api.nvim_create_user_command("MarimoWsPing", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  local server = require("neo-marimo.server")
  local ok = server.send_ws(nb.filepath, {
    op = "neo_marimo_ping",
    ts = vim.uv.hrtime() / 1e6,
  })
  if ok then
    vim.notify("[neo-marimo] Sent WS ping", vim.log.levels.INFO)
  else
    vim.notify("[neo-marimo] WS not connected; can't send ping", vim.log.levels.WARN)
  end
end, { desc = "Send a no-op ping over the marimo WebSocket (for debugging)" })

vim.api.nvim_create_user_command("MarimoWsDebug", function(opts)
  -- Toggle WS message logging. Without args: toggles on/off using a default
  -- path. With an arg: enables logging to that path. Use "off" to disable.
  if opts.args == "off" then
    _G.neo_marimo_ws_log = nil
    vim.notify("[neo-marimo] WS debug logging disabled", vim.log.levels.INFO)
    return
  end
  local path = (opts.args ~= "" and opts.args) or "/tmp/neo-marimo-ws.log"
  _G.neo_marimo_ws_log = path
  -- Truncate so each session starts fresh
  local f = io.open(path, "w")
  if f then f:close() end
  vim.notify("[neo-marimo] WS debug logging → " .. path, vim.log.levels.INFO)
end, { nargs = "?", desc = "Toggle WebSocket message logging (path or 'off')" })

-- Same as the <leader>mo keymap: start the marimo server (if needed) and
-- open the notebook in the browser.
vim.api.nvim_create_user_command("MarimoEdit", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  require("neo-marimo.actions").open_in_browser(nb)
end, { desc = "Start marimo server and open notebook in browser" })

-- `:MarimoRun` runs the cell under the cursor.
-- `:MarimoRun all` runs every cell in the notebook.
vim.api.nvim_create_user_command("MarimoRun", function(opts)
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  local actions = require("neo-marimo.actions")
  if opts.args == "all" then
    actions.run_all_cells(nb.bufnr, nb)
  elseif opts.args == "" then
    actions.run_cell_at_cursor(nb.bufnr, nb)
  else
    vim.notify("[neo-marimo] :MarimoRun expects no arg or 'all'", vim.log.levels.WARN)
  end
end, {
  nargs = "?",
  complete = function() return { "all" } end,
  desc = "Run cell under cursor (or all cells with 'all')",
})

-- `:MarimoNewCell` (defaults to below) inserts a new blank cell relative to
-- the cell under the cursor. Use `above` to put it before.
vim.api.nvim_create_user_command("MarimoNewCell", function(opts)
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  local actions = require("neo-marimo.actions")
  local where = opts.args == "" and "below" or opts.args
  if where == "below" then
    actions.new_cell_below(nb.bufnr, nb)
  elseif where == "above" then
    actions.new_cell_above(nb.bufnr, nb)
  else
    vim.notify("[neo-marimo] :MarimoNewCell expects 'above' or 'below'", vim.log.levels.WARN)
  end
end, {
  nargs = "?",
  complete = function() return { "above", "below" } end,
  desc = "Insert a new blank cell above or below the cursor",
})

-- Phase 8.5: open the side-split DataFrame viewer for the cell under the
-- cursor. The cell must have a `application/vnd.dataresource+json` output;
-- typically that's set by returning a pandas/polars DataFrame.
vim.api.nvim_create_user_command("MarimoDataFramePanel", function()
  require("neo-marimo.dataframe").open_at_cursor()
end, { desc = "Open the full DataFrame side-panel for the cell under cursor" })

-- Diagnostic: dump the cell-under-cursor's output mimetype + first 1.5 KB
-- of its payload plus any widgets we parsed out. Use this when output looks
-- wrong ("why is my mo.md cell rendering as raw HTML?") — paste the buffer
-- contents back so the renderer routing can be matched against the actual
-- bytes marimo sent.
vim.api.nvim_create_user_command("MarimoInspectOutput", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell = require("neo-marimo.notebook").get_cell_at_row(nb, row)
  if not cell then
    vim.notify("[neo-marimo] Cursor is not over a cell.", vim.log.levels.WARN)
    return
  end

  local widgets = require("neo-marimo.widgets")
  local info = {
    cell = {
      id = cell.id,
      name = cell.name,
      index = cell.index,
      type = cell.type,
      status = cell.status,
      has_run = cell._has_run == true,
    },
    output = cell.output and {
      mimetype = cell.output.mimetype,
      data_type = type(cell.output.data),
      data_len = type(cell.output.data) == "string" and #cell.output.data or nil,
      data_sample = type(cell.output.data) == "string"
        and cell.output.data:sub(1, 1500) or cell.output.data,
    } or "<no output>",
    console_lines = cell.console and #cell.console or 0,
    widgets = widgets.list_for_cell(nb.bufnr, cell.id),
  }

  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false,
    vim.split(vim.inspect(info), "\n", { plain = true }))
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "lua", { buf = buf })
  vim.api.nvim_buf_set_name(buf, "marimo://inspect/cell-" .. tostring(cell.id))
end, { desc = "Inspect cell output mimetype + payload + parsed widgets" })

-- Drop every cached widget value override and re-render the notebook so
-- each widget falls back to whatever data-initial-value its current
-- output HTML reports. Use this when an override has gotten stale (e.g.
-- you changed a slider's range and want the new initial value back).
vim.api.nvim_create_user_command("MarimoResetWidgets", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  require("neo-marimo.widgets").clear_all_overrides()
  for _, cell in ipairs(nb.cells) do
    require("neo-marimo.output").render(nb.bufnr, cell, nb.filepath)
  end
  vim.notify("[neo-marimo] Widget overrides cleared.", vim.log.levels.INFO)
end, { desc = "Clear all widget value overrides and re-render" })

-- Phase 8.3: open the widget picker for the cell under the cursor. Lists
-- every UI element marimo emitted in the cell's last output and lets the
-- user adjust its value, which POSTs to /api/kernel/set_ui_element_value
-- and reactively re-runs dependent cells.
vim.api.nvim_create_user_command("MarimoWidget", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell = require("neo-marimo.notebook").get_cell_at_row(nb, row)
  if not cell then
    vim.notify("[neo-marimo] Cursor is not over a cell.", vim.log.levels.WARN)
    return
  end
  require("neo-marimo.widget_picker").open(nb, cell)
end, { desc = "Interact with UI widgets in the cell under cursor" })

-- Phase 10: panel of pinned widgets across the whole notebook. Pin/unpin
-- with the widget_pin keymap (<leader>mP by default).
vim.api.nvim_create_user_command("MarimoWidgetPins", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  require("neo-marimo.widget_picker").open_pins(nb)
end, { desc = "Open the pinned-widgets panel" })

vim.api.nvim_create_user_command("MarimoNew", function(opts)
  local filepath = opts.args ~= "" and opts.args
    or vim.fn.input("New notebook path: ", vim.fn.getcwd() .. "/", "file")
  if not filepath or filepath == "" then return end

  -- Expand ~ and make absolute
  filepath = vim.fn.expand(filepath)
  if not filepath:match("%.py$") then
    filepath = filepath .. ".py"
  end

  -- Refuse to overwrite an existing file
  if vim.fn.filereadable(filepath) == 1 then
    vim.notify("[neo-marimo] File already exists: " .. filepath, vim.log.levels.ERROR)
    return
  end

  local marimo = require("neo-marimo")
  local config = require("neo-marimo.config")
  local parser = require("neo-marimo.parser")

  if not config.options.python_path then
    marimo.setup({})
  end

  -- Generate a minimal notebook with one empty cell
  local python_path = config.options.python_path or "python3"
  local ok, content = pcall(parser.generate_py, {
    { name = "_", code = "", options = {} },
  }, filepath, python_path)

  if not ok then
    vim.notify("[neo-marimo] Failed to generate notebook: " .. tostring(content), vim.log.levels.ERROR)
    return
  end

  -- Write to disk
  local lines = vim.split(content, "\n", { plain = true })
  -- writefile appends a trailing newline; drop the last empty string if present
  if lines[#lines] == "" then table.remove(lines) end
  local write_ok, write_err = pcall(vim.fn.writefile, lines, filepath)
  if not write_ok then
    vim.notify("[neo-marimo] Could not write file: " .. tostring(write_err), vim.log.levels.ERROR)
    return
  end

  -- Open the file in a new buffer and attach the plugin
  vim.cmd.edit(filepath)
  local bufnr = vim.api.nvim_get_current_buf()
  marimo.attach(bufnr)
end, { nargs = "?", complete = "file", desc = "Create a new marimo notebook" })

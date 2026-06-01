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

vim.api.nvim_create_user_command("MarimoServerList", function()
  local server = require("neo-marimo.server")
  local lines = { "## neo-marimo managed servers" }

  local managed = server.list_servers()
  if #managed == 0 then
    table.insert(lines, "  (none)")
  else
    for _, s in ipairs(managed) do
      local age = s.started_at and (os.time() - s.started_at) or 0
      table.insert(lines, string.format(
        "  %s\n    port=%d  pid=%s  alive=%s  ws=%s  token=%s  age=%ds",
        s.filepath, s.port, tostring(s.pid), tostring(s.alive),
        tostring(s.ws_connected), tostring(s.has_token), age
      ))
    end
  end

  table.insert(lines, "")
  table.insert(lines, "## All marimo edit processes on system")
  local procs = server.list_system_marimo_processes()
  if #procs == 0 then
    table.insert(lines, "  (none)")
  else
    for _, p in ipairs(procs) do
      local orphan = (p.ppid == 1) and "  [ORPHAN]" or ""
      table.insert(lines, string.format("  pid=%d ppid=%s%s\n    %s",
        p.pid, tostring(p.ppid), orphan, p.cmd))
    end
    table.insert(lines, "")
    table.insert(lines, "Run :MarimoKillAll to terminate every marimo edit process.")
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "List managed marimo servers and orphan marimo processes" })

vim.api.nvim_create_user_command("MarimoKillAll", function()
  local server = require("neo-marimo.server")
  local n = server.kill_all_system_marimo()
  vim.notify("[neo-marimo] Killed " .. n .. " marimo process(es).", vim.log.levels.INFO)
end, { desc = "Force-kill all marimo edit processes on the system" })

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

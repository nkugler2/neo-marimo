local config = require("neo-marimo.config")
local parser = require("neo-marimo.parser")
local notebook = require("neo-marimo.notebook")
local buffer = require("neo-marimo.buffer")
local sync = require("neo-marimo.sync")
local keymaps = require("neo-marimo.keymaps")
local highlights = require("neo-marimo.highlights")
local server = require("neo-marimo.server")
local utils = require("neo-marimo.utils")
local ws_handlers = require("neo-marimo.ws_handlers")
local watcher = require("neo-marimo.watcher")
local lsp = require("neo-marimo.lsp")

local M = {}

-- Track active notebooks by source filepath to avoid double-attaching
local _attached = {}

-- Set to true around code paths that intentionally load the underlying .py
-- buffer (e.g. :MarimoToggle off). The BufReadPost autocmd in
-- plugin/neo-marimo.lua checks this flag and skips its auto-attach so we
-- don't immediately bounce back into the notebook view.
M._suppress_attach = false

-- Initialize the plugin with user options.
-- Call this from your Neovim config:
--   require("neo-marimo").setup({ python_path = "/path/to/python" })
function M.setup(opts)
  config.setup(opts)
  highlights.setup()
end

-- Check if a buffer's file is a marimo notebook.
-- Returns true if the buffer contains a marimo.App() instantiation.
function M.is_marimo_notebook(bufnr)
  -- Check filetype
  local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  if ft ~= "python" and ft ~= "" then
    return false
  end

  -- Check file extension
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name:match("%.py$") then
    return false
  end

  -- Read first 50 lines for marimo markers
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 50, false)
  local content = table.concat(lines, "\n")

  return content:find("marimo%.App%(") ~= nil
    or content:find("import marimo") ~= nil and content:find("@app%.cell") ~= nil
end

-- Attach the notebook view to a buffer.
-- This reads the file, creates the notebook buffer, and swaps the window.
function M.attach(source_bufnr)
  local filepath = vim.api.nvim_buf_get_name(source_bufnr)

  -- Avoid double-attaching. The buffer must be both valid (not wiped) and
  -- loaded — a :bd leaves the buffer "valid" but unloaded, in which case
  -- switching to it would show an empty buffer and lose all state.
  if _attached[filepath] then
    local existing_nb = _attached[filepath]
    if existing_nb.bufnr
        and vim.api.nvim_buf_is_valid(existing_nb.bufnr)
        and vim.api.nvim_buf_is_loaded(existing_nb.bufnr) then
      vim.api.nvim_win_set_buf(0, existing_nb.bufnr)
      return
    else
      _attached[filepath] = nil
    end
  end

  -- Parse the notebook file
  local python_path = config.options.python_path or "python3"
  local ok, data = pcall(parser.parse_file, filepath, python_path)
  if not ok then
    utils.warn("Failed to parse " .. filepath .. ": " .. tostring(data))
    utils.warn("Make sure python_path in setup() points to a Python with marimo installed.")
    utils.warn("Current python_path: " .. python_path)
    return
  end

  if not data.valid then
    local violations = data.violations or {}
    if #violations > 0 then
      utils.warn("Notebook has parse violations: " .. violations[1].description)
    end
    if not data.cells or #data.cells == 0 then
      utils.warn("No cells found in " .. filepath)
      return
    end
  end

  -- Build notebook state
  local nb = notebook.new(filepath, data)

  -- Build the WS message handler closure. Stored on nb so keymaps can pass it
  -- to server.start_and_open without needing to re-create it each time.
  local nb_bufnr_ref = nil  -- filled in after buffer creation below
  nb._on_ws_message = function(msg)
    local op = msg.op or msg.name
    -- Marimo's wire format wraps everything: {"op": "...", "data": {...}}
    -- Our own ws_client.py status messages (neo_marimo_*) are flat.
    local payload = (type(msg.data) == "table" and msg.data) or msg

    -- Debug logging: when enabled, append every message to a log file so we
    -- can see exactly what marimo is sending. Toggle with :MarimoWsDebug.
    if _G.neo_marimo_ws_log then
      local f = io.open(_G.neo_marimo_ws_log, "a")
      if f then
        f:write(os.date("[%H:%M:%S] ") .. (op or "?") .. " "
          .. vim.json.encode(payload) .. "\n")
        f:close()
      end
    end

    ws_handlers.dispatch(op, payload, {
      nb = nb,
      bufnr = nb_bufnr_ref,
      raw = msg,
    })
  end

  -- Create the visual notebook buffer
  local nb_bufnr = buffer.create(nb, source_bufnr)
  nb_bufnr_ref = nb_bufnr  -- close over the real bufnr

  -- Store notebook state on the buffer (Lua value; cleared when buffer is wiped)
  -- We store it in our module-level table since vim.b can't hold Lua objects directly
  _attached[filepath] = nb

  -- Set up BufWriteCmd to intercept saves
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = nb_bufnr,
    callback = function()
      sync.write_to_file(nb)
    end,
  })

  -- Track edits via nvim_buf_attach's on_bytes hook (debounced flush +
  -- undo-restore matching). Lives in buffer.lua so the headless test
  -- harness attaches the exact wiring production uses.
  buffer.attach_change_tracking(nb_bufnr, nb)

  -- The WinResized/VimResized autocmd below is global (resize events
  -- aren't tied to a buffer), so it must be removed by hand when the
  -- notebook is wiped — otherwise every attach leaks a handler whose
  -- closure pins the entire notebook state for the rest of the session.
  -- Declared here so the BufWipeout cleanup can see it; assigned where
  -- the autocmd is created further down.
  local resize_autocmd_id = nil

  -- Clean up when notebook buffer is explicitly wiped (:bw). With
  -- bufhidden = "hide", this no longer fires on :q or :MarimoToggle —
  -- only when the user really discards the buffer. The server keeps
  -- running unless config.server.stop_on_close opts in to the strict
  -- lifecycle.
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = nb_bufnr,
    once = true,
    callback = function()
      _attached[filepath] = nil
      watcher.stop(filepath)
      lsp.cleanup(filepath)
      if resize_autocmd_id then
        pcall(vim.api.nvim_del_autocmd, resize_autocmd_id)
        resize_autocmd_id = nil
      end
      if config.options.server and config.options.server.stop_on_close
          and server.is_running(filepath) then
        server.stop(filepath)
      end
    end,
  })

  -- Keep the shadow buffer in sync with edits. Debounced so a burst of
  -- keystrokes only triggers one regeneration. 120ms is short enough
  -- that the shadow is almost always current when the user fires
  -- <C-x><C-o>, but long enough to coalesce normal typing.
  local refresh_shadow = utils.debounce(function()
    pcall(lsp.refresh_shadow, nb)
  end, 120)
  vim.api.nvim_buf_attach(nb_bufnr, false, {
    on_bytes = function(_, bnr)
      if bnr ~= nb_bufnr then return true end
      refresh_shadow()
    end,
  })

  -- Prime the shadow once at attach so pyright gets first-look analysis
  -- before the user invokes K. Done via vim.schedule so it doesn't race
  -- the buffer creation (sync_cells_from_buffer would see empty lines).
  vim.schedule(function()
    pcall(lsp.refresh_shadow, nb)
  end)

  -- The notebook buffer needs filetype=python for syntax highlighting,
  -- which also (correctly) trips the user's `vim.lsp.enable("pyright")` /
  -- ruff / lspconfig autostart on FileType=python — and any client that
  -- attaches here triggers the user's own LspAttach autocmd, which in
  -- the common case re-binds K/gd to `vim.lsp.buf.hover` / `definition`,
  -- clobbering our marimo-aware versions. We don't want either side of
  -- that to happen on the notebook buffer (all LSP work belongs on the
  -- shadow), so when something attaches here we immediately detach the
  -- client and re-run our keymap setup to restore K/gd/<C-k>.
  vim.api.nvim_create_autocmd("LspAttach", {
    buffer = nb_bufnr,
    callback = function(args)
      pcall(vim.lsp.buf_detach_client, nb_bufnr, args.data.client_id)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(nb_bufnr) then
          keymaps.setup(nb_bufnr, nb)
        end
      end)
    end,
  })

  -- Watch the .py for external edits (browser saves, other editors).
  -- Skipped if disabled, or if the file doesn't exist on disk yet
  -- (rare: an unsaved-buffer case where attach was called manually).
  local srv_cfg = config.options.server or {}
  if srv_cfg.watch_file ~= false and vim.uv.fs_stat(filepath) then
    watcher.start(filepath, function()
      -- Coalesce with our own save: if this fires inside the
      -- write-suppress window, the change is ours and we already
      -- have the buffer state.
      if sync.is_writing(nb) then return end
      if not vim.api.nvim_buf_is_valid(nb_bufnr) then return end

      -- Hash the file on disk. If it matches one of our recent writes
      -- this is our own change echoing back (e.g. marimo --watch
      -- rewriting the file after a dependent cell re-ran). Skip the
      -- prompt and the reparse entirely.
      local f = io.open(filepath, "rb")
      if f then
        local content = f:read("*a")
        f:close()
        if sync.matches_recent_write(nb, content) then return end
      end

      -- Re-parse from disk, then patch the buffer with the delta.
      local ok, data = pcall(parser.parse_file, filepath, config.options.python_path)
      if not ok or not data or not data.cells then return end

      -- Don't fight the user: if they have unsaved edits, ask before
      -- overwriting. The common case (browser is the active editor
      -- because we released our WS) has no local edits.
      local modified = vim.api.nvim_get_option_value("modified", { buf = nb_bufnr })
      if modified then
        local choice = vim.fn.confirm(
          "External change to " .. vim.fn.fnamemodify(filepath, ":t")
            .. " — discard local edits?",
          "&Yes\n&No", 2
        )
        if choice ~= 1 then return end
      end

      sync.apply_remote_changes(nb, data.cells)
    end)
  end

  -- Switch the current window to show the notebook buffer
  vim.api.nvim_win_set_buf(0, nb_bufnr)
  buffer.apply_window_settings(vim.api.nvim_get_current_win())
  -- Borders rendered inside buffer.create() used the fallback width because
  -- the buffer wasn't in a window yet. Re-render now that we know the real
  -- window width, otherwise cells stay at fallback size until the first edit.
  buffer.render_all_borders(nb_bufnr, nb)

  -- Width-dependent output rendering (hstack column sizing, the wrap pass)
  -- goes stale when the window is resized. Re-render every cell's output at
  -- the new width — debounced, unlike the border redraws, because outputs
  -- are much heavier to rebuild (tree parse + widget walk + possibly image
  -- placements) and mid-drag intermediate widths aren't worth painting.
  local redraw_outputs = utils.debounce(function()
    if not vim.api.nvim_buf_is_valid(nb_bufnr) then return end
    if #vim.fn.win_findbuf(nb_bufnr) == 0 then return end
    local output = require("neo-marimo.output")
    for _, cell in ipairs(nb.cells) do
      if not cell._output_hidden
          and (cell.output or cell.console or cell._has_run) then
        output.render(nb_bufnr, cell, filepath)
      end
    end
  end, 200)

  -- Re-apply window settings whenever the buffer enters a new window
  -- (e.g. user runs :split). Also re-render borders and outputs so they
  -- pick up the new window width.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = nb_bufnr,
    callback = function()
      buffer.apply_window_settings(vim.api.nvim_get_current_win())
      buffer.render_all_borders(nb_bufnr, nb)
      redraw_outputs()
    end,
  })

  -- Adaptive border width: re-render on window resize so the cell borders
  -- always span the visible width. Synchronous (not debounced) so the user
  -- sees borders extend in lockstep as they drag the window wider. The
  -- width cache short-circuits no-op renders, so WinResized firing for
  -- unrelated reasons doesn't thrash extmarks. The earlier 30ms debounce
  -- looked smooth on shrink (where the over-long border is just clipped)
  -- but janky on widen (where the new visible area sat without dashes
  -- until the timer fired).
  local last_width = nil
  local function redraw_borders()
    if not vim.api.nvim_buf_is_valid(nb_bufnr) then return end
    if #vim.fn.win_findbuf(nb_bufnr) == 0 then return end
    local w = buffer.border_width(nb_bufnr)
    if w == last_width then return end
    last_width = w
    buffer.render_all_borders(nb_bufnr, nb)
    redraw_outputs()
  end

  resize_autocmd_id = vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    callback = redraw_borders,
  })

  -- Wipe the original source buffer (we no longer need it displayed)
  -- Use schedule to avoid issues with the autocmd still running
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(source_bufnr) and source_bufnr ~= nb_bufnr then
      pcall(vim.api.nvim_buf_delete, source_bufnr, { force = true })
    end
  end)

  -- Set up keymaps on the notebook buffer
  keymaps.setup(nb_bufnr, nb)

  local cell_count = #nb.cells
  vim.notify(
    string.format("[neo-marimo] Opened %s (%d cells)", vim.fn.fnamemodify(filepath, ":t"), cell_count),
    vim.log.levels.INFO
  )
end

-- Run :checkhealth for this plugin
function M.check()
  local python_path = config.options.python_path or "python3"
  local result = parser.check(python_path)

  if result.ok then
    vim.health.ok("Python bridge OK (Python " .. result.python_version .. ", marimo " .. result.marimo_version .. ")")
  else
    vim.health.error("Python bridge failed: " .. (result.error or "unknown"))
    vim.health.info("Set python_path in setup() to a Python interpreter with marimo installed.")
    vim.health.info("Example: require('neo-marimo').setup({ python_path = '/path/to/venv/bin/python' })")
  end
end

-- Get the notebook state for the current buffer, or nil.
function M.current_notebook()
  local bufname = vim.api.nvim_buf_get_name(0)
  local filepath = bufname:match("^marimo://(.+)$")
  if filepath then
    return _attached[filepath]
  end
  return nil
end

-- Return the notebook state attached to a given source filepath, or nil.
-- Used by the statusline / server list to look up cell counts for files
-- that aren't the current buffer.
function M.attached_for(filepath)
  return _attached[filepath]
end

-- Bind the toggle_view keymap onto a plain (.py) buffer. After the user has
-- toggled off the notebook view at least once, the plain buffer needs the
-- same `<leader>mv` binding so they can toggle back.
local function bind_plain_toggle(pbuf)
  local km = config.options.keymaps or {}
  local lhs = km.toggle_view
  if not lhs then return end
  pcall(vim.keymap.set, "n", lhs, function()
    M.toggle(pbuf)
  end, {
    buffer = pbuf,
    silent = true,
    noremap = true,
    desc = "Marimo: toggle notebook view",
  })
end

-- Swap the current window between the notebook view and the underlying .py.
--
--   * On a `marimo://<path>` buffer → write any pending edits, load the plain
--     .py buffer (suppressing auto-attach), and switch the window to it.
--   * On a plain .py buffer that we've already attached → switch the window
--     back to the cached notebook buffer.
--   * On a plain .py buffer we haven't seen → attach it like a fresh open.
function M.toggle(bufnr)
  bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local marimo_path = bufname:match("^marimo://(.+)$")

  if marimo_path then
    -- Notebook → plain. Persist edits first so the plain buffer reflects the
    -- notebook content; otherwise the on-disk .py is stale relative to what
    -- the user sees.
    local nb = _attached[marimo_path]
    if nb and (nb.dirty or vim.api.nvim_get_option_value("modified", { buf = bufnr })) then
      sync.write_to_file(nb)
    end

    local pbuf = vim.fn.bufadd(marimo_path)
    if pbuf == 0 then
      utils.warn("Could not open underlying .py buffer for " .. marimo_path)
      return
    end

    -- Suppress the BufReadPost auto-attach for this one load. The flag is
    -- read by the scheduled callback in plugin/neo-marimo.lua; we clear it
    -- via vim.schedule so the callback (which is also scheduled) sees it
    -- and bails out, then it's cleared before any future buffer load.
    M._suppress_attach = true
    pcall(vim.fn.bufload, pbuf)
    vim.schedule(function() M._suppress_attach = false end)

    bind_plain_toggle(pbuf)
    vim.api.nvim_win_set_buf(0, pbuf)
    return
  end

  -- We're on a plain .py. Switch to the cached notebook buffer if we have
  -- one and it's still loaded; otherwise attach fresh.
  local filepath = bufname
  if filepath == "" then
    utils.warn("Buffer has no filename — nothing to toggle.")
    return
  end

  local existing = _attached[filepath]
  if existing
      and existing.bufnr
      and vim.api.nvim_buf_is_valid(existing.bufnr)
      and vim.api.nvim_buf_is_loaded(existing.bufnr) then
    vim.api.nvim_win_set_buf(0, existing.bufnr)
    return
  end

  if M.is_marimo_notebook(bufnr) then
    M.attach(bufnr)
  else
    utils.warn("Not a marimo notebook — cannot toggle.")
  end
end

-- ── Extension points ──────────────────────────────────────────────────────
--
-- These three registries are the supported way to extend neo-marimo without
-- patching it. Everything else — module functions not re-exported here or
-- documented in docs/architecture.md, and anything prefixed with `_` — is
-- internal and may change between commits.

-- Register (or replace) the ASCII renderer for a widget name. `name` is the
-- suffix of marimo's `<marimo-{name}>` element normalised to snake_case
-- ("text-area" → "text_area"). `fn(w)` receives the widget table (name,
-- object_id, value, options, label, focused, …) and must return a list of
-- virt_lines, where each virt_line is a list of `{text, hl_group}` chunks.
-- See docs/architecture.md ("The virt_line chunk contract") for details.
function M.register_widget_renderer(name, fn)
  require("neo-marimo.widgets").register_renderer(name, fn)
end

-- Register (or replace) the output renderer for a mimetype. `mime` is an
-- exact mimetype ("text/csv") or a prefix pattern ("image/*"); patterns are
-- consulted after exact matches. `fn(data, opts, mimetype)` receives the
-- CellOutput payload and must return a list of virt_lines (same chunk
-- contract as widget renderers).
function M.register_output_renderer(mime, fn)
  require("neo-marimo.output").register_renderer(mime, fn)
end

-- Register (or replace) the handler for a WebSocket op. `fn(payload, ctx)`
-- receives the message's `data` field (or the whole message when there is
-- none) and ctx = { nb = <notebook>, bufnr = <notebook buffer>, raw = msg }.
function M.register_ws_handler(op, fn)
  require("neo-marimo.ws_handlers").register(op, fn)
end

-- Register a cell-type detector. `predicate(code)` is tried against each
-- cell's source (lower `priority` first; built-ins use 10–30) and the first
-- match sets the cell's type — which drives its border colour and label.
function M.register_cell_detector(predicate, type_name, priority)
  require("neo-marimo.cell").register_detector(predicate, type_name, priority)
end

return M

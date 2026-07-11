local M = {}

M.defaults = {
  -- Path to Python interpreter that has marimo installed.
  -- Override if marimo is in a virtualenv:
  --   python_path = "/path/to/venv/bin/python"
  -- ### This was the original value before me changing it for updated marimo environment
  -- python_path = "python3",

  python_path = "/Users/noahkugler/.pyenv/versions/MarimoLatest/bin/python",
  marimo_cmd  = "/Users/noahkugler/.pyenv/versions/MarimoLatest/bin/marimo",

  -- The marimo CLI command (for opening in browser)
  -- ### This was the original value before me changing it for updated marimo environment
  -- marimo_cmd = "marimo",

  -- Marimo server settings (Phase 2)
  server = {
    -- Host the marimo server binds to, passed through as `marimo edit
    -- --host`. Defaults to 127.0.0.1 (loopback only), which is also the
    -- address every HTTP/WS call in this plugin connects to — keep them
    -- in sync (e.g. don't set "localhost" if it resolves to ::1 on your
    -- box, or the client's 127.0.0.1 calls won't reach the server).
    --
    -- SECURITY: the server is launched with `--no-token` (no
    -- authentication), so binding to a non-loopback address ("0.0.0.0",
    -- a LAN IP, …) publishes an UNAUTHENTICATED arbitrary-Python
    -- execution endpoint to the network. neo-marimo warns when host is
    -- not loopback. Read SECURITY.md before changing this.
    host = "127.0.0.1",
    port = 2718,
    auto_start = true,
    -- Stop the marimo server when the notebook buffer is wiped (:bw).
    -- Default false so :MarimoToggle and accidental :bd don't terminate
    -- a running kernel; flip on if you want a strict lifecycle.
    stop_on_close = false,
    -- Release our WebSocket connection when the user opens the notebook
    -- in the browser, so the browser can take the single EDIT-mode
    -- connection slot. Turn off if you'd rather lose the browser than
    -- give up the nvim live-update stream.
    share_with_browser = true,
    -- Delay (ms) between releasing our WS slot and reconnecting as a kiosk
    -- during the browser hand-off (server.lua hand_off_to_browser) — gives
    -- the browser time to win the single EDIT-mode slot first. Timing-
    -- dependent on machine speed: raise it if the browser loses the race
    -- and shows "Network already connected".
    browser_handoff_delay_ms = 1200,
    -- Watch the .py file for external edits (browser saves, other
    -- editors). When a change is detected, the notebook view is
    -- refreshed from disk.
    watch_file = true,
  },

  -- Inline-image handling (plan-refinement F2.7).
  images = {
    -- Sweep the terminal's kitty-graphics state once, on the first
    -- notebook attach of the session, but only inside tmux. Kitty
    -- placements drawn through tmux passthrough outlive nvim — the
    -- terminal keeps the pixels and tmux never tracks or repaints them —
    -- so a crashed or force-quit session leaves fossils that the next
    -- session's placements land on top of. Attach time, before the first
    -- attach's own render, is the only moment a delete-all is guaranteed
    -- not to hit one of our own live placements. Trade-off: it also
    -- clears images drawn by any other program sharing the same tmux
    -- pane/window surface; set to false if that matters to you (recover a
    -- stuck fossil later with :MarimoImageRepaint instead).
    tmux_sweep_on_attach = true,
  },

  -- Visual settings
  ui = {
    -- "rounded" uses box-drawing chars, "simple" uses dashes, "none" hides borders
    border_style = "rounded",
    -- Show cell name in the border label
    show_cell_name = true,
    -- Show cell index (1, 2, 3...) in border
    show_cell_index = true,
    -- Soft-wrap code inside cells so long lines stay visible without horizontal scroll
    wrap_cells = true,
    -- Wrap cell *output* (virt_lines) at the window width. virt_lines
    -- neither wrap nor scroll horizontally, so without this anything past
    -- the right edge — long markdown prose, wide tables, long stdout
    -- lines — is simply invisible.
    wrap_output = true,
    -- Show nerd-font glyphs in the cell label. Disable for non-nerd-font setups.
    icons = true,
  },

  -- Keymaps (set any to false to disable)
  keymaps = {
    next_cell = "]m",
    prev_cell = "[m",
    new_cell_below = "<leader>mn",
    new_cell_above = "<leader>mN",
    delete_cell = "<leader>md",
    move_cell_down = "<leader>mJ",
    move_cell_up = "<leader>mK",
    open_in_browser = "<leader>mo",
    -- Start the server in nvim-only mode: nvim holds the editor session and
    -- renders all output inline, and NO browser tab is opened. Use this when
    -- you want marimo entirely inside neovim; use open_in_browser (<leader>mo)
    -- to also drive/observe from the marimo web editor.
    start = "<leader>ms",
    stop_server = "<leader>mx",
    run_cell = "<leader>mr",
    run_all = "<leader>mR",
    -- Interrupt whatever the kernel is currently executing — the escape
    -- hatch for runaway cells (infinite loops, huge loads).
    interrupt = "<leader>mi",
    -- Restart the kernel: outputs and statuses are cleared, the server
    -- process is recycled, and nothing re-runs until you ask (run_all).
    restart_kernel = "<leader>mX",
    toggle_output = "<leader>mt",
    -- Swap the current window between the notebook view (marimo://...) and
    -- the underlying .py buffer. Bound on both buffers once the toggle has
    -- been used at least once.
    toggle_view = "<leader>mv",
    -- Reclaim the WebSocket connection from the browser. After
    -- <leader>mo / :MarimoEdit we release our WS so the browser can
    -- connect; press this to take it back (e.g. after closing the
    -- browser tab) and resume live updates in nvim.
    reclaim_ws = "<leader>mc",
    -- LSP keymaps (Phase 7). Routed through a hidden shadow buffer so
    -- the user's existing Python LSP (pyright, basedpyright, pylsp)
    -- works inside the notebook view. Set any to false to disable.
    hover           = "K",
    signature_help  = "<C-k>",   -- insert mode
    goto_definition = "gd",
    -- Completion: when truthy, `omnifunc` on the notebook buffer is
    -- pointed at neo-marimo's LSP-backed completion driver (used by
    -- <C-x><C-o> and any completion plugin that respects omnifunc).
    completion      = true,
    -- Phase 8.5: open a side-split panel showing the full DataFrame
    -- output for the cell under the cursor (no row cap; `s` to sort).
    dataframe_panel = "<leader>mD",
    -- Phase 10: interact with the UI widgets in the cell under the
    -- cursor (slider, button, dropdown, …). Smart: a focused widget (or a
    -- cell with exactly one widget) is acted on directly with no menu;
    -- multi-widget cells open the ordered picker, where digits 1-9 act
    -- immediately and <Tab>/<S-Tab> cycle between mo.ui.tabs groups.
    widget_picker   = "<leader>mw",
    -- Open the full tab-aware widget picker unconditionally.
    widget_picker_full = "<leader>mW",
    -- Focus the next/previous widget in the cell under the cursor (wraps;
    -- jumps to the nearest cell with widgets when the current cell has
    -- none). The focused widget shows a ▸ marker in the output.
    next_widget     = "]w",
    prev_widget     = "[w",
    -- Re-open the edit prompt for the last-edited widget, wherever it
    -- lives — one keystroke per iteration when tweaking a value.
    widget_last     = "<leader>m.",
    -- Pin/unpin the focused (or last-edited) widget, and open the panel
    -- of pinned widgets across the whole notebook.
    widget_pin      = "<leader>mP",
    widget_pins     = "<leader>mp",
    -- Nudge the focused slider/number/range_slider by its step without a
    -- prompt. Only fires when the focused (▸) widget is in the cell under
    -- the cursor; otherwise the native <C-a>/<C-x> increment/decrement
    -- still applies to numbers in code.
    widget_nudge_up   = "<C-a>",
    widget_nudge_down = "<C-x>",
  },
}

-- Merged config (populated by init.setup)
M.options = {}

function M.setup(user_opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
end

-- Look up a config value by dot-separated path (e.g. "server.port",
-- "python_path"). M.setup() deep-merges M.defaults with the user's table
-- with "force" (user wins), so M.options normally already carries every
-- default key by the time setup() has run. This exists for two reasons
-- (plan-refinement F5.3): call sites were re-encoding default literals
-- (`or "python3"`, `or 2718`, ...) that silently drift from config.defaults
-- the moment a default changes, and several sites indexed
-- `config.options.server.port` unguarded — which errors if setup() hasn't
-- run yet (M.options starts as `{}`, not M.defaults) e.g. code paths that
-- read config before the auto-setup-on-first-attach in plugin/neo-marimo.lua
-- has fired. get() walks M.options first and falls back to M.defaults at
-- whatever depth is missing or nil, so it's safe pre-setup too.
function M.get(path)
  local keys = vim.split(path, ".", { plain = true })

  local function walk(root)
    local cur = root
    for _, k in ipairs(keys) do
      if type(cur) ~= "table" then return nil end
      cur = cur[k]
    end
    return cur
  end

  local value = walk(M.options)
  if value ~= nil then return value end
  return walk(M.defaults)
end

return M

local M = {}

M.defaults = {
  -- Path to Python interpreter that has marimo installed.
  -- Override if marimo is in a virtualenv:
  --   python_path = "/path/to/venv/bin/python"
  python_path = "python3",

  -- The marimo CLI command (for opening in browser)
  marimo_cmd = "marimo",

  -- Marimo server settings (Phase 2)
  server = {
    host = "localhost",
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
    -- Watch the .py file for external edits (browser saves, other
    -- editors). When a change is detected, the notebook view is
    -- refreshed from disk.
    watch_file = true,
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
    stop_server = "<leader>mx",
    run_cell = "<leader>mr",
    run_all = "<leader>mR",
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

return M

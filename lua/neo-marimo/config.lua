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
  },
}

-- Merged config (populated by init.setup)
M.options = {}

function M.setup(user_opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
end

return M

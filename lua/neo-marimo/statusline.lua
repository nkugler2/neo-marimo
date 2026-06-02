-- Statusline helpers for neo-marimo (TOCHANGE.md #6 / roadmap Phase 5.2).
--
-- Designed to be cheap to call on every statusline redraw. The functions
-- never raise — they prefer to return an empty string so a misconfigured
-- statusline doesn't blank the bar.
--
-- Wiring example (lualine):
--   require("lualine").setup({
--     sections = {
--       lualine_x = { require("neo-marimo.statusline").component },
--     },
--   })

local M = {}

-- Cheap require so a stripped-down install (e.g. tests) that hasn't pulled
-- in the rest of neo-marimo doesn't blow up when the statusline is built.
local function try_require(mod)
  local ok, m = pcall(require, mod)
  if not ok then return nil end
  return m
end

local function icons_on()
  local config = try_require("neo-marimo.config")
  if not config or not config.options or not config.options.ui then
    return true
  end
  return config.options.ui.icons ~= false
end

local TYPE_SHORT = {
  python   = "py",
  markdown = "md",
  sql      = "sql",
  marimo   = "mo",
}

-- Per-cell "py · #3 / 12" descriptor for the current notebook buffer.
-- Returns nil when not on a notebook buffer or when the cursor isn't
-- inside any cell (shouldn't happen, but be defensive).
function M.current_cell()
  local marimo = try_require("neo-marimo")
  local notebook = try_require("neo-marimo.notebook")
  if not marimo or not notebook then return nil end

  local nb = marimo.current_notebook()
  if not nb then return nil end

  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell = notebook.get_cell_at_row(nb, row)
  if not cell then return nil end

  local short = TYPE_SHORT[cell.type] or cell.type or "py"
  return string.format("%s #%d/%d", short, cell.index, #nb.cells)
end

-- Array of {filepath, port, ws_connected, has_token, alive, pid,
-- started_at, cell_count} for every marimo server the plugin manages.
-- Re-uses server.list_servers and enriches each entry with the cell count
-- from the attached notebook (when present).
function M.servers()
  local server = try_require("neo-marimo.server")
  local marimo = try_require("neo-marimo")
  if not server then return {} end

  local list = server.list_servers()
  for _, s in ipairs(list) do
    local nb = marimo and marimo.attached_for(s.filepath)
    s.cell_count = nb and #nb.cells or 0
  end
  return list
end

-- Short status string suitable for lualine_x or similar slots.
--   * Empty string when there's no marimo activity at all.
--   * "󰀘 marimo · 2 servers" when not on a notebook buffer but servers are alive.
--   * "󰀘 marimo · 1 server · py #3/12" when on a notebook buffer.
function M.component()
  local server = try_require("neo-marimo.server")
  local marimo = try_require("neo-marimo")

  local server_count = 0
  if server and server._servers then
    for _, srv in pairs(server._servers) do
      if srv.job_id and vim.fn.jobwait({ srv.job_id }, 0)[1] == -1 then
        server_count = server_count + 1
      end
    end
  end

  local nb = marimo and marimo.current_notebook()
  if not nb and server_count == 0 then return "" end

  local icon = icons_on() and "󰀘 " or ""
  local parts = { icon .. "marimo" }

  if server_count > 0 then
    parts[#parts + 1] = server_count == 1
      and "1 server"
      or (server_count .. " servers")
  end

  local cell_info = M.current_cell()
  if cell_info then
    parts[#parts + 1] = cell_info
  end

  return table.concat(parts, " · ")
end

return M

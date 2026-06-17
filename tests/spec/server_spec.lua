-- start_and_open's "already running" branch: when neovim currently holds the
-- main WS slot (server started nvim-only via start_headless, browser_active
-- false), pressing <leader>mo must hand the slot to the browser — release our
-- WS, open the tab — not just open a tab the browser can't connect through.
-- When the browser already holds main, it must just reopen the tab.

local t = require("helpers")
local server = require("neo-marimo.server")
local config = require("neo-marimo.config")

-- Run `fn` with server I/O methods stubbed to record calls. Restores
-- everything (and vim.defer_fn) afterward so cases don't leak state.
local function with_stubs(fn)
  config.setup({})
  local calls = { release = 0, open = 0, connect = 0 }
  local orig = {
    is_running = server.is_running,
    release_ws = server.release_ws,
    open_browser = server.open_browser,
    connect_ws = server.connect_ws,
    defer = vim.defer_fn,
  }
  server.is_running = function() return true end
  server.release_ws = function() calls.release = calls.release + 1; return true end
  server.open_browser = function() calls.open = calls.open + 1 end
  server.connect_ws = function() calls.connect = calls.connect + 1; return true end
  vim.defer_fn = function() end  -- swallow the deferred kiosk reconnect timer
  local ok, err = pcall(fn, calls)
  server.is_running = orig.is_running
  server.release_ws = orig.release_ws
  server.open_browser = orig.open_browser
  server.connect_ws = orig.connect_ws
  vim.defer_fn = orig.defer
  if not ok then error(err) end
end

t.case("server: <leader>mo on an nvim-only server hands the slot to the browser", function()
  with_stubs(function(calls)
    local fp = "/tmp/nm_server_spec_main.py"
    server._servers[fp] = { browser_active = false, on_message = function() end }
    server.start_and_open({ filepath = fp }, function() end)
    server._servers[fp] = nil
    t.eq(calls.release, 1, "released our main WS so the browser can take the slot")
    t.eq(calls.open, 1, "opened the browser tab")
  end)
end)

t.case("server: <leader>mo when the browser already holds main just reopens the tab", function()
  with_stubs(function(calls)
    local fp = "/tmp/nm_server_spec_browser.py"
    server._servers[fp] = { browser_active = true, on_message = function() end }
    server.start_and_open({ filepath = fp }, function() end)
    server._servers[fp] = nil
    t.eq(calls.release, 0, "did not release again — browser already holds main")
    t.eq(calls.open, 1, "reopened the browser tab")
  end)
end)

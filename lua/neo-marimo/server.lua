-- neo-marimo server management and HTTP/WebSocket client.
--
-- Manages one marimo server process per notebook file. Tracks the job IDs
-- so the server can be stopped cleanly and reused across <leader>mo presses.

local config = require("neo-marimo.config")
local utils = require("neo-marimo.utils")

local M = {}

-- module-level table: filepath -> server state
-- {
--   job_id       = number,   marimo server job
--   ws_job_id    = number,   ws_client.py job
--   port         = number,
--   session_id   = string,   UUID used in HTTP headers + WS URL
--   access_token = string|nil, token parsed from marimo's startup URL
--   browser_url  = string,   the full URL marimo printed (may include token)
--   instantiated = bool,
--   on_message   = function, callback for WS messages
-- }
M._servers = {}

local ws_client_path = utils.plugin_root() .. "/python/ws_client.py"

-- ── helpers ────────────────────────────────────────────────────────────────

local function api_url(srv, path)
  local base = "http://127.0.0.1:" .. tostring(srv.port) .. path
  if srv.access_token then
    base = base .. "?access_token=" .. srv.access_token
  end
  return base
end

-- Synchronous HTTP GET. Returns body string or nil on error.
local function http_get(url)
  local r = vim.system({ "curl", "-s", "--max-time", "3", url }, { text = true }):wait()
  if r.code ~= 0 then return nil end
  return r.stdout
end

-- Synchronous HTTP POST with JSON body.
-- Returns decoded body table or nil on error.
local function http_post(url, body, session_id)
  local json_body, err = utils.json_encode(body)
  if err then
    utils.warn("http_post encode error: " .. err)
    return nil
  end

  local args = {
    "curl", "-s", "--max-time", "10",
    "-X", "POST",
    "-H", "Content-Type: application/json",
  }
  if session_id then
    table.insert(args, "-H")
    table.insert(args, "Marimo-Session-Id: " .. session_id)
  end
  table.insert(args, "-d")
  table.insert(args, json_body)
  table.insert(args, url)

  local r = vim.system(args, { text = true }):wait()
  if r.code ~= 0 then return nil end

  local data, decode_err = utils.json_decode(r.stdout)
  if decode_err then return nil end
  return data
end

-- Parse the URL from a line of marimo's startup output.
-- Marimo prints: "  ➜  URL: http://localhost:PORT?access_token=XXX"
local function parse_startup_url(line)
  -- Strip ANSI escape codes first
  local clean = line:gsub("\27%[[%d;]*m", "")
  local url = clean:match("URL:%s*(https?://%S+)")
  if not url then return nil, nil, nil end

  -- Normalise localhost -> 127.0.0.1
  url = url:gsub("^http://localhost:", "http://127.0.0.1:")

  local port = tonumber(url:match(":(%d+)"))
  local token = url:match("[?&]access_token=([^&%s]+)")
  return url, port, token
end

-- Poll the server health endpoint until it responds or timeout (ms).
local function wait_for_server(port, timeout_ms)
  local url = "http://127.0.0.1:" .. tostring(port) .. "/health"
  local elapsed = 0
  local interval = 200

  while elapsed < timeout_ms do
    local body = http_get(url)
    if body and body:find("healthy") then
      return true
    end
    vim.uv.sleep(interval)
    elapsed = elapsed + interval
  end
  return false
end

-- Generate a UUID v4-like string for session IDs.
local function new_session_id()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end)
end

-- ── public API ─────────────────────────────────────────────────────────────

-- Check whether a server tracked by us is currently alive.
function M.is_running(filepath)
  local srv = M._servers[filepath]
  if not srv then return false end
  local status = vim.fn.jobwait({ srv.job_id }, 0)
  return status[1] == -1
end

-- Start a headless marimo server for the given notebook.
-- Returns the server state table, or nil on failure.
function M.start(filepath, port, on_message)
  port = port or config.options.server.port or 2718
  local marimo_cmd = config.options.marimo_cmd or "marimo"

  if M.is_running(filepath) then
    return M._servers[filepath]
  end

  local session_id = new_session_id()

  -- srv is created early so the on_stdout closure can write to it
  local srv = {
    job_id = nil,
    ws_job_id = nil,
    port = port,
    session_id = session_id,
    access_token = nil,
    browser_url = nil,
    instantiated = false,
    on_message = on_message,
  }
  M._servers[filepath] = srv

  -- Start marimo in headless mode. We intentionally do NOT pass --no-token so
  -- that if marimo requires auth, we capture the token from its startup output
  -- and use it for every subsequent request.
  local job_id = vim.fn.jobstart(
    { marimo_cmd, "edit", "--headless", "--port", tostring(port), filepath },
    {
      -- Capture both streams to find the startup URL marimo prints
      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          local url, parsed_port, token = parse_startup_url(line)
          if url and not srv.browser_url then
            srv.browser_url = url
            if parsed_port then srv.port = parsed_port end
            srv.access_token = token  -- nil when --no-token was used
          end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data) do
          local url, parsed_port, token = parse_startup_url(line)
          if url and not srv.browser_url then
            srv.browser_url = url
            if parsed_port then srv.port = parsed_port end
            srv.access_token = token
          end
        end
      end,
      on_exit = function(_, code)
        if M._servers[filepath] and M._servers[filepath].job_id == job_id then
          M._servers[filepath] = nil
        end
      end,
    }
  )

  if job_id <= 0 then
    M._servers[filepath] = nil
    utils.error("Failed to start marimo server. Is '" .. marimo_cmd .. "' on PATH?")
    return nil
  end

  srv.job_id = job_id
  return srv
end

-- Stop the marimo server and WebSocket client for this notebook.
function M.stop(filepath)
  local srv = M._servers[filepath]
  if not srv then
    vim.notify("[neo-marimo] No server running for this notebook.", vim.log.levels.WARN)
    return
  end

  if srv.ws_job_id then
    pcall(vim.fn.jobstop, srv.ws_job_id)
    srv.ws_job_id = nil
  end

  pcall(vim.fn.jobstop, srv.job_id)
  M._servers[filepath] = nil

  vim.notify("[neo-marimo] Server stopped.", vim.log.levels.INFO)
end

-- Connect a WebSocket client to the running server.
function M.connect_ws(filepath, on_message)
  local srv = M._servers[filepath]
  if not srv then
    utils.error("No server state for " .. filepath)
    return false
  end

  local python_path = config.options.python_path or "python3"

  -- Pass the access token to ws_client.py so it can include it in the WS URL
  local ws_args = { python_path, ws_client_path, tostring(srv.port), srv.session_id, filepath }
  if srv.access_token then
    table.insert(ws_args, srv.access_token)
  end

  local ws_job_id = vim.fn.jobstart(ws_args, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          local msg, err = utils.json_decode(line)
          if not err and msg then
            vim.schedule(function()
              local current_srv = M._servers[filepath]
              if current_srv and current_srv.on_message then
                current_srv.on_message(msg)
              end
            end)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          vim.schedule(function() utils.warn("ws_client: " .. line) end)
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          utils.warn("WebSocket client exited (code " .. tostring(code) .. ")")
        end)
      end
    end,
  })

  if ws_job_id <= 0 then
    utils.error("Failed to start WebSocket client")
    return false
  end

  srv.ws_job_id = ws_job_id
  if on_message then srv.on_message = on_message end
  return true
end

-- Send HTTP POST /api/kernel/instantiate.
function M.instantiate(filepath)
  local srv = M._servers[filepath]
  if not srv then return false end

  local result = http_post(
    api_url(srv, "/api/kernel/instantiate"),
    { objectIds = {}, values = {}, autoRun = true },
    srv.session_id
  )

  if result and result.success then
    srv.instantiated = true
    return true
  end
  return false
end

-- Send HTTP POST /api/kernel/run for one or more cells.
function M.run_cells(filepath, cell_ids, codes)
  local srv = M._servers[filepath]
  if not srv then
    utils.warn("No marimo server running. Press <leader>mo to start.")
    return false
  end

  local result = http_post(
    api_url(srv, "/api/kernel/run"),
    { cellIds = cell_ids, codes = codes },
    srv.session_id
  )

  return result ~= nil and result.success == true
end

-- Open the browser using the exact URL marimo printed on startup.
function M.open_browser(filepath)
  local srv = M._servers[filepath]
  if not srv then return end

  -- Use the URL marimo gave us (which already has the token if auth is on).
  -- Fall back to bare URL only if we somehow never got the startup output.
  local url = srv.browser_url or ("http://127.0.0.1:" .. tostring(srv.port))
  vim.fn.jobstart({ "open", url }, { detach = true })
  vim.notify("[neo-marimo] Opening " .. url:gsub("%?.*", "") .. " ...", vim.log.levels.INFO)
end

-- Full start-and-open flow: start server if needed, wait for ready, connect
-- WS, instantiate kernel, then open browser.
function M.start_and_open(nb, on_message)
  local filepath = nb.filepath
  local port = config.options.server.port or 2718

  if M.is_running(filepath) then
    M.open_browser(filepath)
    return
  end

  vim.notify("[neo-marimo] Starting marimo server...", vim.log.levels.INFO)

  local srv = M.start(filepath, port, on_message)
  if not srv then return end

  vim.defer_fn(function()
    local ready = wait_for_server(port, 10000)
    if not ready then
      utils.error("Marimo server did not start within 10 seconds.")
      M.stop(filepath)
      return
    end

    vim.notify("[neo-marimo] Server ready. Connecting...", vim.log.levels.INFO)

    M.connect_ws(filepath, on_message)

    vim.defer_fn(function()
      M.instantiate(filepath)
      M.open_browser(filepath)
    end, 500)
  end, 0)
end

return M

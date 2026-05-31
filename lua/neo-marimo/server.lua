-- neo-marimo server management and HTTP/WebSocket client.
--
-- Manages one marimo server process per notebook file. Tracks the job IDs
-- so the server can be stopped cleanly and reused across <leader>mo presses.

local config = require("neo-marimo.config")
local utils = require("neo-marimo.utils")

local M = {}

-- module-level table: filepath -> server state
-- {
--   job_id      = number,   marimo server job
--   ws_job_id   = number,   ws_client.py job
--   port        = number,
--   session_id  = string,   UUID used in HTTP headers + WS URL
--   instantiated = bool,
--   on_message  = function, callback for WS messages (set by caller)
-- }
M._servers = {}

local ws_client_path = utils.plugin_root() .. "/python/ws_client.py"

-- ── helpers ────────────────────────────────────────────────────────────────

local function base_url(port)
  return "http://127.0.0.1:" .. tostring(port)
end

-- Synchronous HTTP GET. Returns body string or nil on error.
local function http_get(url)
  local r = vim.system({ "curl", "-s", "--max-time", "3", url }, { text = true }):wait()
  if r.code ~= 0 then return nil end
  return r.stdout
end

-- Synchronous HTTP POST with JSON body and optional Marimo-Session-Id header.
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

-- Poll the server health endpoint until it responds or timeout (ms).
local function wait_for_server(port, timeout_ms)
  local url = base_url(port) .. "/health"
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

-- Generate a simple UUID v4-like string for session IDs.
local function new_session_id()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end)
end

-- ── public API ─────────────────────────────────────────────────────────────

-- Check whether a server is currently tracked (and its process is alive).
function M.is_running(filepath)
  local srv = M._servers[filepath]
  if not srv then return false end
  -- jobwait with 0 timeout: returns -1 if still running
  local status = vim.fn.jobwait({ srv.job_id }, 0)
  return status[1] == -1
end

-- Start a headless marimo server for the given notebook.
-- Returns the server state table, or nil on failure.
function M.start(filepath, port, on_message)
  port = port or config.options.server.port or 2718
  local marimo_cmd = config.options.marimo_cmd or "marimo"
  local python_path = config.options.python_path or "python3"

  -- If already running on this port just return existing state
  if M.is_running(filepath) then
    return M._servers[filepath]
  end

  -- Start the marimo server in headless mode (no browser, no auth token)
  local job_id = vim.fn.jobstart(
    { marimo_cmd, "edit", "--headless", "--no-token", "--port", tostring(port), filepath },
    {
      on_exit = function(_, code)
        -- Clean up state when the server exits
        if M._servers[filepath] and M._servers[filepath].job_id == job_id then
          M._servers[filepath] = nil
        end
      end,
      -- Suppress marimo's own log output from polluting :messages
      on_stdout = function() end,
      on_stderr = function() end,
    }
  )

  if job_id <= 0 then
    utils.error("Failed to start marimo server. Is '" .. marimo_cmd .. "' on PATH?")
    return nil
  end

  local session_id = new_session_id()

  local srv = {
    job_id = job_id,
    ws_job_id = nil,
    port = port,
    session_id = session_id,
    instantiated = false,
    on_message = on_message,
  }
  M._servers[filepath] = srv
  return srv
end

-- Stop the marimo server and WebSocket client for this notebook.
function M.stop(filepath)
  local srv = M._servers[filepath]
  if not srv then
    vim.notify("[neo-marimo] No server running for this notebook.", vim.log.levels.WARN)
    return
  end

  -- Kill WS client first (it's a child of the server effectively)
  if srv.ws_job_id then
    pcall(vim.fn.jobstop, srv.ws_job_id)
    srv.ws_job_id = nil
  end

  -- Kill the marimo server
  pcall(vim.fn.jobstop, srv.job_id)
  M._servers[filepath] = nil

  vim.notify("[neo-marimo] Server stopped.", vim.log.levels.INFO)
end

-- Connect a WebSocket client to the running server.
-- `on_message(msg_table)` is called for each message received.
function M.connect_ws(filepath, on_message)
  local srv = M._servers[filepath]
  if not srv then
    utils.error("No server state for " .. filepath)
    return false
  end

  local python_path = config.options.python_path or "python3"

  local ws_job_id = vim.fn.jobstart(
    { python_path, ws_client_path, tostring(srv.port), srv.session_id, filepath },
    {
      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          if line ~= "" then
            local msg, err = utils.json_decode(line)
            if not err and msg then
              vim.schedule(function()
                local current_on_message = (M._servers[filepath] or {}).on_message
                if current_on_message then
                  current_on_message(msg)
                end
              end)
            end
          end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data) do
          if line ~= "" then
            vim.schedule(function()
              utils.warn("ws_client: " .. line)
            end)
          end
        end
      end,
      on_exit = function(_, code)
        if code ~= 0 then
          vim.schedule(function()
            utils.warn("WebSocket client exited with code " .. tostring(code))
          end)
        end
      end,
    }
  )

  if ws_job_id <= 0 then
    utils.error("Failed to start WebSocket client")
    return false
  end

  srv.ws_job_id = ws_job_id
  if on_message then
    srv.on_message = on_message
  end
  return true
end

-- Send HTTP POST /api/kernel/instantiate to start cell execution.
function M.instantiate(filepath)
  local srv = M._servers[filepath]
  if not srv then return false end

  local result = http_post(
    base_url(srv.port) .. "/api/kernel/instantiate",
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
-- `cell_ids` and `codes` are parallel lists.
function M.run_cells(filepath, cell_ids, codes)
  local srv = M._servers[filepath]
  if not srv then
    utils.warn("No marimo server running. Press <leader>mo to start.")
    return false
  end

  local result = http_post(
    base_url(srv.port) .. "/api/kernel/run",
    { cellIds = cell_ids, codes = codes },
    srv.session_id
  )

  return result ~= nil and result.success == true
end

-- Open the browser pointing at the running server.
function M.open_browser(filepath)
  local srv = M._servers[filepath]
  if not srv then return end
  local url = "http://127.0.0.1:" .. tostring(srv.port)
  vim.fn.jobstart({ "open", url }, { detach = true })
  vim.notify("[neo-marimo] Opening " .. url .. " ...", vim.log.levels.INFO)
end

-- Full start-and-open flow: start server if needed, wait for it, connect WS,
-- instantiate kernel, then open browser. Calls `on_message` for WS messages.
-- `nb` is the notebook state table; `on_message` is a function(msg).
function M.start_and_open(nb, on_message)
  local filepath = nb.filepath
  local port = config.options.server.port or 2718
  local python_path = config.options.python_path or "python3"

  if M.is_running(filepath) then
    -- Server already up — just open browser
    M.open_browser(filepath)
    return
  end

  vim.notify("[neo-marimo] Starting marimo server...", vim.log.levels.INFO)

  local srv = M.start(filepath, port, on_message)
  if not srv then return end

  -- Poll in background (can't block the UI)
  vim.defer_fn(function()
    local ready = wait_for_server(port, 10000)  -- 10 second timeout
    if not ready then
      utils.error("Marimo server did not start within 10 seconds.")
      M.stop(filepath)
      return
    end

    vim.notify("[neo-marimo] Server ready. Connecting...", vim.log.levels.INFO)

    -- Connect WebSocket
    M.connect_ws(filepath, on_message)

    -- Give WS a moment to connect before instantiating
    vim.defer_fn(function()
      M.instantiate(filepath)
      M.open_browser(filepath)
    end, 500)
  end, 0)
end

return M

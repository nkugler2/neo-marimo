-- neo-marimo server management and HTTP/WebSocket client.
--
-- Manages one marimo server process per notebook file. Tracks the job IDs
-- so the server can be stopped cleanly and reused across <leader>mo presses.
--
-- Auth model (marimo has two separate tokens):
--   * access_token  – browser auth, disabled via --no-token
--   * server_token  – skew-protection, REQUIRED on every API request as
--                     the "Marimo-Server-Token" header. It is generated
--                     per-server-start and embedded in the HTML page as
--                     <marimo-server-token data-token="...">. We fetch
--                     the HTML once after the server reports healthy and
--                     cache the token on the server state.

local config = require("neo-marimo.config")
local utils = require("neo-marimo.utils")

local M = {}

-- module-level table: filepath -> server state
-- {
--   job_id       = number,    marimo server job
--   ws_job_id    = number,    ws_client.py job
--   port         = number,
--   session_id   = string,    UUID used in HTTP headers + WS URL
--   server_token = string|nil, skew-protection token from HTML
--   instantiated = bool,
--   on_message   = function,  callback for WS messages
-- }
M._servers = {}

local ws_client_path = utils.plugin_root() .. "/python/ws_client.py"

-- ── helpers ────────────────────────────────────────────────────────────────

local function api_url(srv, path)
  return "http://127.0.0.1:" .. tostring(srv.port) .. path
end

-- URL-encode a path so it can be used as ?file=...
local function url_encode(s)
  return (s:gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- Synchronous HTTP GET. Returns body string or nil on error.
local function http_get(url)
  local r = vim.system({ "curl", "-s", "--max-time", "3", url }, { text = true }):wait()
  if r.code ~= 0 then return nil end
  return r.stdout
end

-- Synchronous HTTP POST with JSON body.
-- Always sends Marimo-Session-Id + Marimo-Server-Token headers when present.
-- Returns decoded body table or nil on error.
local function http_post(srv, path, body)
  local json_body, err = utils.json_encode(body)
  if err then
    utils.warn("http_post encode error: " .. err)
    return nil
  end

  local args = {
    "curl", "-s", "--max-time", "10",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-H", "Marimo-Session-Id: " .. srv.session_id,
  }
  if srv.server_token then
    table.insert(args, "-H")
    table.insert(args, "Marimo-Server-Token: " .. srv.server_token)
  end
  table.insert(args, "-d")
  table.insert(args, json_body)
  table.insert(args, api_url(srv, path))

  local r = vim.system(args, { text = true }):wait()
  if r.code ~= 0 then return nil end

  local data, decode_err = utils.json_decode(r.stdout)
  if decode_err then return nil end
  return data
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

-- Fetch the notebook HTML and extract the skew-protection server token.
local function fetch_server_token(port, filepath)
  local url = "http://127.0.0.1:" .. tostring(port) .. "/?file=" .. url_encode(filepath)
  local html = http_get(url)
  if not html then return nil end
  return html:match('<marimo%-server%-token[^>]*data%-token="([^"]+)"')
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

  local srv = {
    job_id = nil,
    ws_job_id = nil,
    port = port,
    session_id = session_id,
    server_token = nil,
    instantiated = false,
    on_message = on_message,
  }
  M._servers[filepath] = srv

  -- --no-token disables the browser-auth access_token entirely. We still
  -- need to capture the actual port marimo picks (it may differ from our
  -- requested port if there's a conflict), so we tail stdout.
  local job_id = vim.fn.jobstart(
    { marimo_cmd, "edit", "--headless", "--no-token", "--port", tostring(port), filepath },
    {
      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          -- Strip ANSI escapes first
          local clean = line:gsub("\27%[[%d;]*m", "")
          local p = clean:match("URL:%s*https?://[^:]+:(%d+)")
          if p then srv.port = tonumber(p) end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data) do
          local clean = line:gsub("\27%[[%d;]*m", "")
          local p = clean:match("URL:%s*https?://[^:]+:(%d+)")
          if p then srv.port = tonumber(p) end
        end
      end,
      on_exit = function(_, _)
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

  -- access_token arg is intentionally omitted: --no-token disables it.
  local ws_args = { python_path, ws_client_path, tostring(srv.port), srv.session_id, filepath }

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

  local result = http_post(srv, "/api/kernel/instantiate", {
    objectIds = {}, values = {}, autoRun = true,
  })

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

  local result = http_post(srv, "/api/kernel/run", {
    cellIds = cell_ids, codes = codes,
  })

  return result ~= nil and result.success == true
end

-- Open the notebook in a browser. No auth needed since --no-token is set;
-- we just construct the URL ourselves from the (possibly updated) port.
function M.open_browser(filepath)
  local srv = M._servers[filepath]
  if not srv then return end

  local url = "http://127.0.0.1:" .. tostring(srv.port) .. "/?file=" .. url_encode(filepath)
  vim.fn.jobstart({ "open", url }, { detach = true })
  vim.notify("[neo-marimo] Opening " .. url, vim.log.levels.INFO)
end

-- Full start-and-open flow: start server if needed, wait for ready, fetch
-- the server token from the HTML, connect WS, instantiate kernel, then open
-- the browser.
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
    local ready = wait_for_server(srv.port, 10000)
    if not ready then
      utils.error("Marimo server did not start within 10 seconds.")
      M.stop(filepath)
      return
    end

    -- Fetch the skew-protection token before any API call. Without this all
    -- POSTs would 401 with "Missing server token".
    srv.server_token = fetch_server_token(srv.port, filepath)
    if not srv.server_token then
      utils.warn("Could not extract server token from HTML; API calls may fail.")
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

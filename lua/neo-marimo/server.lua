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
--
-- Port-conflict handling: we never trust the configured port (default 2718)
-- blindly. Before spawning marimo we probe ports and pick the first free
-- one starting from the configured port. This prevents the failure mode
-- where an orphan `marimo edit` (or a different nvim session) already
-- holds 2718, our --port flag is silently ignored by the OS, /health
-- passes against the foreign server, and every API call fails with
-- "Missing server token" because the foreign server has a different token
-- (or no extractable token at all because its HTML 303s to /auth/login).

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
-- Uses -f so curl exits non-zero on 4xx/5xx (otherwise we'd silently treat a
-- 303 redirect body, an auth-login page, etc. as a valid response).
local function http_get(url)
  local r = vim.system({ "curl", "-sf", "--max-time", "3", url }, { text = true }):wait()
  if r.code ~= 0 then return nil end
  return r.stdout
end

-- Check whether a TCP port is currently being listened on by anything.
-- Used by find_free_port so we don't end up sharing a port with an orphan
-- marimo (or any other process), in which case marimo would fail to bind
-- silently and we'd be talking to whatever is already there.
local function port_in_use(port)
  local tcp = vim.uv.new_tcp()
  if not tcp then return true end
  local done, in_use = false, false
  tcp:connect("127.0.0.1", port, function(err)
    in_use = (err == nil)
    done = true
    pcall(function() tcp:close() end)
  end)
  -- Bounded wait: anything beyond a few hundred ms is pathological for
  -- a loopback probe.
  vim.wait(300, function() return done end, 10)
  if not done then
    pcall(function() tcp:close() end)
    return true  -- conservatively treat unresponsive as in use
  end
  return in_use
end

-- Find a port that is not in use, starting at start_port and scanning up.
-- Returns the first free port within `attempts` tries, or nil if none.
local function find_free_port(start_port, attempts)
  for offset = 0, attempts - 1 do
    local p = start_port + offset
    if not port_in_use(p) then
      return p
    end
  end
  return nil
end

-- Synchronous HTTP POST. Returns {status, body} on completion (regardless
-- of HTTP code) or nil if curl itself failed. Status is a string ("200")
-- so callers can compare without parsing.
--
-- Always sends Marimo-Session-Id + Marimo-Server-Token headers when present.
local function http_post_raw(srv, path, body)
  local json_body, err = utils.json_encode(body)
  if err then
    utils.warn("http_post encode error: " .. err)
    return nil
  end

  -- -w "\n%{http_code}" puts the HTTP status code on its own trailing line so
  -- we can surface non-2xx responses (otherwise curl silently returns an
  -- error body and we'd think the request succeeded).
  local args = {
    "curl", "-s", "--max-time", "10",
    "-w", "\n%{http_code}",
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
  if r.code ~= 0 then
    utils.warn("POST " .. path .. " failed: curl exit " .. tostring(r.code))
    return nil
  end

  local body_str, status = r.stdout:match("^(.*)\n(%d+)%s*$")
  if not status then
    body_str = r.stdout
    status = "?"
  end
  return { status = status, body = body_str or "" }
end

-- JSON variant. Returns decoded body table or nil on error/non-2xx.
-- Used for endpoints like /api/kernel/run that respond with JSON; for
-- endpoints that respond with text/plain (e.g. /api/kernel/save) use
-- http_post_raw directly so the caller can check status without a
-- spurious decode failure.
local function http_post(srv, path, body)
  local r = http_post_raw(srv, path, body)
  if not r then return nil end
  if r.status ~= "200" then
    utils.warn("POST " .. path .. " → HTTP " .. r.status .. ": " .. r.body)
    return nil
  end
  local data, decode_err = utils.json_decode(r.body)
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
  local start_port = port or config.options.server.port or 2718
  local marimo_cmd = config.options.marimo_cmd or "marimo"

  if M.is_running(filepath) then
    return M._servers[filepath]
  end

  -- Pick a free port up front. Without this an orphan process on the
  -- configured port silently steals every request: marimo --port fails
  -- to bind, but /health on that port still passes (against the orphan),
  -- and all our subsequent API calls 401 with the wrong server's token.
  local actual_port = find_free_port(start_port, 20)
  if not actual_port then
    utils.error(
      "No free port in range " .. start_port .. ".." .. (start_port + 19) ..
        ". Run :MarimoServerList to see what is using them."
    )
    return nil
  end
  if actual_port ~= start_port then
    vim.notify(
      "[neo-marimo] Port " .. start_port .. " in use; using " .. actual_port .. ".",
      vim.log.levels.INFO
    )
  end

  local session_id = new_session_id()

  local srv = {
    job_id = nil,
    ws_job_id = nil,
    port = actual_port,
    requested_port = start_port,
    session_id = session_id,
    server_token = nil,
    instantiated = false,
    on_message = on_message,
    started_at = os.time(),
    filepath = filepath,
  }
  M._servers[filepath] = srv

  -- --no-token disables the browser-auth access_token entirely. We still
  -- watch stdout for the URL line in case marimo's bind races with us and
  -- it has to fall back to a different port.
  local job_id = vim.fn.jobstart(
    { marimo_cmd, "edit", "--headless", "--no-token", "--port", tostring(actual_port), filepath },
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
-- SIGTERM via jobstop is not enough on its own: marimo launches a kernel
-- subprocess which can survive when the parent dies (becoming a PPID=1
-- orphan that keeps the port bound). We wait for the job to exit and
-- then force-kill any leftover children so the port is genuinely free
-- next time the user restarts.
function M.stop(filepath)
  local srv = M._servers[filepath]
  if not srv then
    vim.notify("[neo-marimo] No server running for this notebook.", vim.log.levels.WARN)
    return
  end

  -- Snapshot job IDs + PID and clear M._servers up front. The marimo job's
  -- on_exit callback also clears the table, so doing it here first avoids a
  -- TOCTOU window where a concurrent start_and_open could otherwise see a
  -- half-stopped server and skip its own startup.
  local job_id = srv.job_id
  local ws_job_id = srv.ws_job_id
  local pid = job_id and vim.fn.jobpid(job_id) or nil
  M._servers[filepath] = nil

  if ws_job_id then pcall(vim.fn.jobstop, ws_job_id) end
  if job_id then
    pcall(vim.fn.jobstop, job_id)
    vim.fn.jobwait({ job_id }, 2000)
  end

  -- Belt-and-suspenders: SIGKILL the original PID and any direct children.
  -- pkill -P only reaches direct children; that's enough for marimo's normal
  -- shape (parent + kernel subprocess) but not deeper trees. If a deeper
  -- orphan is suspected, :MarimoKillAll is the user-facing escape hatch.
  if pid and pid > 0 then
    pcall(function() vim.system({ "pkill", "-9", "-P", tostring(pid) }, {}):wait(1000) end)
    pcall(function() vim.system({ "kill", "-9", tostring(pid) }, {}):wait(500) end)
  end

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
            -- Mark the WS as live the moment we see our own
            -- neo_marimo_connected sentinel. start_and_open waits on this
            -- flag before opening the browser, otherwise the browser races
            -- our ws_client.py for the single allowed EDIT-mode connection
            -- and our session never gets created (HTTP 500 "Invalid session id").
            if msg.op == "neo_marimo_connected" then
              local current_srv = M._servers[filepath]
              if current_srv then current_srv.ws_connected = true end
            end
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

-- Gracefully release our WebSocket connection so another client (browser)
-- can grab the single EDIT-mode connection slot. Keeps the marimo server
-- itself running. Sets srv.browser_active = true so the rest of the code
-- can tell that the WS is intentionally absent rather than crashed.
function M.release_ws(filepath)
  local srv = M._servers[filepath]
  if not srv then return false end
  if srv.ws_job_id then
    pcall(vim.fn.jobstop, srv.ws_job_id)
    srv.ws_job_id = nil
  end
  srv.ws_connected = false
  srv.browser_active = true
  return true
end

-- Reclaim the WebSocket connection after it was released to the browser.
-- Re-runs connect_ws using the cached on_message, blocks briefly until the
-- handshake lands, and re-instantiates the kernel so cell-op messages start
-- flowing again. Returns true on success.
function M.reclaim_ws(filepath)
  local srv = M._servers[filepath]
  if not srv then
    utils.warn("No server running for this notebook.")
    return false
  end
  if srv.ws_connected then
    vim.notify("[neo-marimo] WebSocket already connected.", vim.log.levels.INFO)
    return true
  end
  if not srv.on_message then
    utils.warn("No WS message handler cached — cannot reclaim.")
    return false
  end

  srv.ws_connected = false
  local ok = M.connect_ws(filepath, srv.on_message)
  if not ok then return false end

  local connected = vim.wait(5000, function()
    return srv.ws_connected == true
  end, 50)

  if not connected then
    utils.warn("Reclaim: WebSocket did not connect within 5s.")
    return false
  end

  srv.browser_active = false
  -- Re-instantiate so the kernel re-sends cell-op messages for the
  -- current state. Without this we'd sit idle until the user pressed
  -- run again.
  M.instantiate(filepath)
  vim.notify("[neo-marimo] WebSocket reclaimed.", vim.log.levels.INFO)
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
    -- POSTs would 401 with "Missing server token". This doubles as an
    -- identity check: if the HTML doesn't contain a token element, we are
    -- not talking to a --no-token server (probably an orphan that requires
    -- auth and 303s us to /auth/login). Bail loudly rather than continue
    -- with a half-broken connection where WS 403s and HTTP 401s.
    srv.server_token = fetch_server_token(srv.port, filepath)
    if not srv.server_token then
      utils.error(
        "Could not authenticate with marimo server on port " .. srv.port ..
          ". Most likely an orphan `marimo edit` is holding the port " ..
          "(`pgrep -fl marimo` to check, then `:MarimoKillAll` to clean up)."
      )
      M.stop(filepath)
      return
    end

    vim.notify("[neo-marimo] Server ready. Connecting...", vim.log.levels.INFO)

    srv.ws_connected = false
    M.connect_ws(filepath, on_message)

    -- Block until ws_client.py has actually completed its handshake.
    -- vim.wait yields to the event loop so on_stdout can set ws_connected.
    -- If we open the browser before this, the browser's WS wins the single
    -- EDIT-mode connection slot and our HTTP requests 500 with
    -- "Invalid session id" because no session was ever created for us.
    local connected = vim.wait(5000, function()
      return srv.ws_connected == true
    end, 50)

    if not connected then
      utils.warn("WebSocket client didn't connect within 5s; opening browser anyway.")
    end

    M.instantiate(filepath)

    -- Marimo's EDIT mode allows exactly one WS connection per file. The
    -- browser we're about to open needs that slot — if we hold on to it,
    -- the browser tab reports "Network already connected" and never
    -- becomes usable. Release ours first, then open. The user can press
    -- <leader>mc (reclaim_ws) when they close the browser tab and want
    -- nvim to take the slot back.
    if config.options.server.share_with_browser ~= false then
      M.release_ws(filepath)
    end
    M.open_browser(filepath)
  end, 0)
end

-- Push cell codes to the running marimo server via /api/kernel/save.
-- Marimo will write the file itself, but we still call this so its
-- in-memory view of the notebook matches what we just persisted. Without
-- it, the running server lags behind disk by ~1s while its own file
-- watcher catches up.
--
-- `cells` is an ordered list of cell tables with fields `id`, `name`,
-- `code`, and `options`. The cell IDs must match what the server
-- assigned at kernel-ready time, otherwise marimo rejects the request.
function M.save_cells(filepath, cells)
  local srv = M._servers[filepath]
  if not srv then return false end

  local cell_ids = {}
  local codes = {}
  local names = {}
  local configs = {}
  for _, cell in ipairs(cells) do
    table.insert(cell_ids, cell.id)
    table.insert(codes, cell.code or "")
    table.insert(names, cell.name or "_")
    -- vim.empty_dict() round-trips as {} rather than [] — required so
    -- marimo's msgspec decoder accepts CellConfig{} for empty options.
    local opts = cell.options
    if type(opts) ~= "table" or next(opts) == nil then
      opts = vim.empty_dict()
    end
    table.insert(configs, opts)
  end

  -- /api/kernel/save responds with the saved file contents as
  -- text/plain (not JSON), so we use the raw helper and check the HTTP
  -- status directly instead of going through http_post's JSON decode.
  local r = http_post_raw(srv, "/api/kernel/save", {
    cellIds = cell_ids,
    codes = codes,
    names = names,
    configs = configs,
    filename = filepath,
    persist = true,
  })
  if not r then return false end
  if r.status ~= "200" then
    utils.warn("POST /api/kernel/save → HTTP " .. r.status .. ": " .. r.body)
    return false
  end
  return true
end

-- ── introspection ─────────────────────────────────────────────────────────

-- Return an array of {filepath, port, pid, ws_connected, has_token,
-- started_at} for every server we currently manage. Used by
-- :MarimoServerList and by statusline integrations (TOCHANGE.md #6).
function M.list_servers()
  local result = {}
  for filepath, srv in pairs(M._servers) do
    local alive = srv.job_id and vim.fn.jobwait({ srv.job_id }, 0)[1] == -1
    table.insert(result, {
      filepath = filepath,
      port = srv.port,
      pid = srv.job_id and vim.fn.jobpid(srv.job_id) or nil,
      ws_connected = srv.ws_connected == true,
      has_token = srv.server_token ~= nil,
      alive = alive,
      started_at = srv.started_at,
    })
  end
  return result
end

-- True if at least one plugin-managed marimo server is currently alive.
-- Cheap to call; safe for use from statusline functions.
function M.is_any_running()
  for _, srv in pairs(M._servers) do
    if srv.job_id and vim.fn.jobwait({ srv.job_id }, 0)[1] == -1 then
      return true
    end
  end
  return false
end

-- List every marimo edit process on the system (whether or not we started
-- it). Returns array of {pid, ppid, cmd}. Used by :MarimoServerList to
-- surface orphans that the plugin can't see in its own state.
function M.list_system_marimo_processes()
  -- pgrep -fl: full command line. -d \n is the default.
  local r = vim.system({ "pgrep", "-fl", "marimo edit" }, { text = true }):wait()
  if r.code ~= 0 or not r.stdout or r.stdout == "" then return {} end

  local procs = {}
  for line in r.stdout:gmatch("[^\n]+") do
    local pid, cmd = line:match("^(%d+)%s+(.+)$")
    if pid then
      pid = tonumber(pid)
      local ppid_r = vim.system({ "ps", "-o", "ppid=", "-p", tostring(pid) }, { text = true }):wait()
      local ppid = ppid_r.code == 0 and tonumber((ppid_r.stdout:gsub("%s+", ""))) or nil
      table.insert(procs, { pid = pid, ppid = ppid, cmd = cmd })
    end
  end
  return procs
end

-- Force-kill every marimo edit process on the system, plugin-managed or not.
-- Returns the number of PIDs we attempted to kill. Used by :MarimoKillAll
-- as the nuclear-option recovery when the start_and_open identity check
-- fails because an orphan is holding the port.
function M.kill_all_system_marimo()
  -- Clean up our own state first so subsequent starts don't reuse stale entries.
  for filepath, _ in pairs(M._servers) do
    pcall(M.stop, filepath)
  end

  local procs = M.list_system_marimo_processes()
  for _, p in ipairs(procs) do
    pcall(function() vim.system({ "kill", "-9", tostring(p.pid) }, {}):wait(500) end)
  end
  return #procs
end

return M

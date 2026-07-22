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

-- F5.2: resync_ws (the self-heal path output.lua calls when a cell-op
-- arrives for an unknown cell id) must emit a "resync:dispatch" trace to
-- :MarimoWsDebug — this async transport was previously silent, so a
-- desync bug report had nothing to grep in the one file R3.3 tells
-- reporters to attach.
t.case("server: resync_ws writes a resync:dispatch entry when ws logging is enabled", function()
  config.setup({})
  local orig_connect = server.connect_ws
  server.connect_ws = function() return true end
  local fp = "/tmp/nm_server_spec_resync.py"
  server._servers[fp] = { on_message = function() end, ws_job_id = 42, ws_kiosk = true }
  local log_path = vim.fn.tempname()
  _G.neo_marimo_ws_log = log_path
  local dispatched = server.resync_ws(fp)
  _G.neo_marimo_ws_log = nil
  server._servers[fp] = nil
  server.connect_ws = orig_connect

  t.eq(dispatched, true, "resync_ws reported a dispatched reconnect")
  local f = io.open(log_path, "r")
  local contents = f and f:read("*a") or ""
  if f then f:close() end
  os.remove(log_path)
  t.match(contents, "resync:dispatch")
end)

-- Regression: a large cell-op (a matplotlib PNG) is one multi-megabyte JSON
-- line that Neovim's jobstart splits across several on_stdout chunks. The
-- handler MUST reassemble partial lines before decoding, or every fragment of
-- the big output fails json.decode and is silently dropped — which is why
-- figures/images never rendered while small single-chunk outputs did.

-- Drive M._reassemble_stdout with a sequence of chunks and collect the
-- complete lines it emits.
local function feed_chunks(chunks)
  local emitted = {}
  local buf = ""
  for _, data in ipairs(chunks) do
    buf = server._reassemble_stdout(buf, data, function(line)
      table.insert(emitted, line)
    end)
  end
  return emitted, buf
end

t.case("server: reassembles a line split across chunks", function()
  -- "abc\ndef" trickling in. jobstart leaves a trailing "" as the partial
  -- right after a newline; the next chunk's first element continues the new
  -- (so far empty) line — there is no extra leading "".
  local emitted, tail = feed_chunks({
    { "ab" },          -- partial: "ab"
    { "c", "" },       -- "abc" completed by the newline, new partial ""
    { "de" },          -- continues the fresh line: "de"
    { "f" },           -- partial: "def"
  })
  t.eq(emitted, { "abc" }, "only the newline-terminated line is emitted")
  t.eq(tail, "def", "the unterminated remainder is carried in the buffer")
end)

t.case("server: large JSON line spanning many chunks decodes once whole", function()
  local payload = string.rep("x", 500000)
  local msg = vim.json.encode({ op = "cell-op", data = payload })
  -- Simulate the kernel of the bug: the single JSON line arrives in 1 KB
  -- slices (as a pipe would deliver a multi-MB line), newline only at the end.
  local chunks = {}
  for i = 1, #msg, 1024 do
    table.insert(chunks, { msg:sub(i, i + 1023) })
  end
  table.insert(chunks, { "", "" })  -- final newline: completes the line

  local emitted = feed_chunks(chunks)
  t.eq(#emitted, 1, "the fragmented line is stitched into exactly one message")
  local decoded = vim.json.decode(emitted[1])
  t.eq(decoded.op, "cell-op")
  t.eq(#decoded.data, 500000, "the full payload survived reassembly")
end)

t.case("server: multiple complete lines in one chunk all emit", function()
  local emitted = feed_chunks({ { "one", "two", "three" } })
  -- "one\ntwo\n" complete; "three" is the trailing partial.
  t.eq(emitted, { "one", "two" })
end)

-- F7.1 regression: if ws_client.py is killed mid-write (or the pipe just
-- closes) the final on_stdout chunk has no trailing newline, so the last
-- fragment is a permanent partial. It must stay buffered and never be
-- handed to dispatch_line as a "complete" line — that would feed a
-- truncated JSON fragment straight into json_decode and (previously)
-- vanish with no diagnostic at all.
t.case("server: a stream that dies mid-fragment never emits the incomplete partial", function()
  local emitted, tail = feed_chunks({
    { '{"op":"cell-op", "da' },  -- ws_client.py dies right here, no newline ever arrives
  })
  t.eq(emitted, {}, "the incomplete fragment must never surface as a completed line")
  t.eq(tail, '{"op":"cell-op", "da', "it stays parked in the buffer instead of being lost")
end)

-- Drive M._decode_ws_line (the seam dispatch_line calls) with log.write
-- stubbed, so the drop-undecodable branch is exercised directly rather than
-- just its precondition. Restores the real log.write in a finally-style pcall.
local function decode_capturing_log(line)
  local log = require("neo-marimo.log")
  local real_write = log.write
  local logged = {}
  log.write = function(tag, meta) table.insert(logged, { tag = tag, meta = meta }) end
  local ok, msg, err = pcall(server._decode_ws_line, line)
  log.write = real_write
  assert(ok, msg)
  return msg, err, logged
end

-- F7.1: a stray "\r" (e.g. CRLF-shaped framing from some future transport
-- bug) survives reassembly unchanged — _reassemble_stdout only splits on
-- "\n", it does not normalize line endings. vim.json.decode treats trailing
-- whitespace (including "\r") as insignificant per RFC 8259, so a
-- \r-suffixed but otherwise complete line is TOLERATED transparently by
-- _decode_ws_line; no stripping needed and no drop-log fires.
t.case("server: a \\r-suffixed but complete line is tolerated, no drop-log", function()
  local emitted = feed_chunks({ { '{"op":"cell-op"}\r', "" } })
  t.eq(emitted, { '{"op":"cell-op"}\r' }, "reassembly does not strip the trailing \\r")
  local msg, err, logged = decode_capturing_log(emitted[1])
  t.eq(err, nil, "trailing \\r is insignificant whitespace — no drop")
  t.eq(msg and msg.op, "cell-op", "the message decodes correctly despite the \\r")
  t.eq(#logged, 0, "the tolerated line must not emit a drop-undecodable log entry")
end)

t.case("server: a genuinely malformed line hits the drop-undecodable log branch", function()
  -- Reassembly reported this as a "complete" line (newline seen), but the
  -- content itself is truncated/corrupt — the exact failure mode the
  -- log-and-drop branch reports instead of swallowing silently.
  local emitted = feed_chunks({ { '{"op":"cell-op"', "" } })
  t.eq(emitted, { '{"op":"cell-op"' })
  local msg, err, logged = decode_capturing_log(emitted[1])
  t.eq(msg, nil, "truncated JSON does not decode, so the line is dropped")
  t.ok(err ~= nil, "an error is surfaced to the caller")
  t.eq(#logged, 1, "exactly one drop-undecodable entry is logged")
  t.eq(logged[1].tag, "ws:drop-undecodable", "logged under the F7.1 tag")
  t.eq(logged[1].meta.len, #emitted[1], "logs the line length")
  t.ok(logged[1].meta.err ~= nil, "logs the decode error")
  -- The line body must NEVER be logged — it can be multi-megabyte.
  for k, v in pairs(logged[1].meta) do
    t.ok(k == "len" or k == "err", "unexpected log field: " .. tostring(k))
    if type(v) == "string" then
      t.ok(v ~= emitted[1], "the raw line body must never appear in the log meta")
    end
  end
end)

-- F1.3 regression: ws_client.py used to exit 0 on an abnormal WS close (the
-- async-for over the socket raised ConnectionClosedError inside a task, and
-- asyncio.wait() silently discarded the never-inspected exception). A dead
-- WS looked exactly like a clean shutdown, so on_exit above never warned and
-- an in-flight run stayed stuck at "queued". This drives the real
-- ws_client.main() (not a Lua-side reimplementation of the fix) via a small
-- standalone script — see tests/ws_client_smoke.py for why that's a plain
-- script instead of a pytest harness (this is the first Python-side test in
-- the repo). Requires a `websockets`-equipped python; self-skips otherwise.
local py = vim.fn.expand(vim.env.NEO_MARIMO_TEST_PYTHON or "python3")
local py_has_websockets = vim.fn.executable(py) == 1
  and vim.system({ py, "-c", "import websockets" }):wait().code == 0

if not py_has_websockets then
  io.write("[server_spec] skipped ws_client smoke check: no websockets-equipped python"
    .. " (set NEO_MARIMO_TEST_PYTHON)\n")
else
  t.case("server: ws_client.py exits nonzero and reports neo_marimo_error on abnormal WS close", function()
    local script = t.root .. "/tests/ws_client_smoke.py"
    local result = vim.system({ py, script }, { stdin = "" }):wait()
    t.eq(result.code, 0, "smoke script assertions failed: " .. tostring(result.stderr))
    t.match(result.stdout, "SMOKE_OK")
  end)
end

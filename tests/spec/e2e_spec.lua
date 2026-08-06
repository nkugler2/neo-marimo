-- Gated end-to-end smoke tests (T3): drive a REAL marimo kernel through
-- server.lua's actual start/connect/run/stop machinery, no stubs, no
-- transcript. This is the layer that catches "the T1 transcripts (and T2's
-- replay of them) no longer match what a real kernel actually sends" — a
-- class of regression the replay layer can't see by construction, since it
-- replays exactly what was recorded. Not meant to run on every edit: run
-- before release, or after touching server.lua / ws_client.py.
--
-- Gated exactly like bridge_spec.lua: self-skips cleanly without a
-- marimo-equipped NEO_MARIMO_TEST_PYTHON, so `make test` stays green on any
-- machine.

local t = require("helpers")

local py = vim.fn.expand(vim.env.NEO_MARIMO_TEST_PYTHON or "python3")
local available = vim.fn.executable(py) == 1
  and vim.system({ py, "-c", "import marimo" }):wait().code == 0

if not available then
  io.write("[e2e_spec] skipped: no marimo-equipped python"
    .. " (set NEO_MARIMO_TEST_PYTHON)\n")
  return
end

-- python_path (bridge.py parse/generate) and marimo_cmd (the kernel server
-- executable) are separate config knobs, and config.lua's own default for
-- marimo_cmd points at the maintainer's personal pyenv env — almost
-- certainly not what NEO_MARIMO_TEST_PYTHON points to. Deriving marimo_cmd
-- from PYTHON's own sibling `marimo` binary is the only way to guarantee we
-- spawn the same install bridge.py just parsed against; a mismatched pair
-- previously produced a confusingly wrong recording in T1 (see
-- docs/plan-testing.md T1's note) — same fix, same reasoning, reused here
-- verbatim from tests/record_transcripts.lua.
local MARIMO_CMD = vim.fn.fnamemodify(py, ":h") .. "/marimo"
if vim.fn.executable(MARIMO_CMD) ~= 1 then
  io.write("[e2e_spec] skipped: no `marimo` executable next to " .. py
    .. " (looked for " .. MARIMO_CMD .. ")\n")
  return
end

local config = require("neo-marimo.config")
local parser = require("neo-marimo.parser")
local notebook = require("neo-marimo.notebook")
local buffer = require("neo-marimo.buffer")
local sync = require("neo-marimo.sync")
local server = require("neo-marimo.server")
local actions = require("neo-marimo.actions")
local widgets = require("neo-marimo.widgets")
local ws_handlers = require("neo-marimo.ws_handlers")
local hl = require("neo-marimo.highlights")

-- Pin the hash seed before spawning anything, for the same reason
-- tests/record_transcripts.lua does: marimo's static analysis of a cell
-- walks `set`s of assigned/used names, and the default randomized hash seed
-- makes iterating one of those sets non-deterministic across runs. Not load-
-- bearing for the scenarios below (none broadcast a multi-name `variables`
-- op that this suite asserts on), but harmless insurance against a future
-- scenario reintroducing exactly the flake T1 hit.
vim.fn.setenv("PYTHONHASHSEED", "0")

local SCENARIOS_DIR = t.root .. "/tests/scenarios"
local _counter = 0

-- Copy a scenario .py to a throwaway path per case (never run against the
-- committed tests/scenarios/*.py in place — edit_rerun's case rewrites cell
-- code mid-test, and that file is committed source, not scratch state).
local function copy_scenario(name)
  local src_path = SCENARIOS_DIR .. "/" .. name .. ".py"
  local f = assert(io.open(src_path, "r"), "missing scenario: " .. src_path)
  local content = f:read("*a")
  f:close()

  _counter = _counter + 1
  local tmp_dir = vim.fn.tempname() .. "-e2e" .. _counter
  vim.fn.mkdir(tmp_dir, "p")
  local tmp_path = tmp_dir .. "/" .. name .. ".py"
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  vim.fn.writefile(lines, tmp_path)
  return tmp_path, tmp_dir
end

-- Read the current text of a cell's ns_output extmark by id — the exact
-- mark output.render() (re)creates on every render pass (see output.lua's
-- M.render: the old mark is deleted by id and a fresh one set at the end).
-- Reading by id rather than scanning the whole buffer's ns_output marks
-- keeps each assertion pinned to one specific cell, so a numeric substring
-- shared between two cells' outputs (e.g. "1" inside another cell's "10")
-- can't produce a false pass.
local function cell_output_text(bufnr, cell)
  if not cell._output_mark_id then return "" end
  local ok, mark = pcall(
    vim.api.nvim_buf_get_extmark_by_id, bufnr, hl.ns_output, cell._output_mark_id, { details = true })
  if not ok or not mark or not mark[3] then return "" end
  return t.joined(mark[3].virt_lines)
end

-- Word-bounded numeric match (mirrors helpers.lua's H.SCRUB_RULES %f[...]
-- frontier-pattern idiom) so asserting "2" ran can't accidentally match
-- inside an unrelated "20"/"12" elsewhere in the same cell's rendered text.
local function has_number(text, n)
  return text:find("%f[%d]" .. n .. "%f[%D]") ~= nil
end

-- Build a real notebook + real "marimo://" buffer for a throwaway copy of
-- `scenario`, run `fn(ctx)` against it, and tear everything down afterward
-- — server stopped, buffer wiped, temp dir removed — REGARDLESS of whether
-- `fn` passed or threw. Without this, one failing case would leave its
-- marimo server running and its config mutated, cascading a port conflict
-- (server.lua's own identity check, which this suite must not work around)
-- or a wrong python_path into every case that runs after it.
local function with_notebook(scenario, fn)
  local filepath, tmp_dir = copy_scenario(scenario)
  local prev_config = vim.deepcopy(config.options)
  config.setup({ python_path = py, marimo_cmd = MARIMO_CMD })

  -- Setup (parse/create/attach) runs inside the same pcall boundary as
  -- `fn`: a throw in parser.parse_file or buffer.create must not skip the
  -- cleanup below, or config.options stays pointed at the test python for
  -- every spec that runs after this one in the same nvim -l process.
  local bufnr
  local ok, err = pcall(function()
    local data = parser.parse_file(filepath, py)
    local nb = notebook.new(filepath, data)
    bufnr = buffer.create(nb, nil)
    buffer.attach_change_tracking(bufnr, nb)
    vim.api.nvim_set_current_buf(bufnr)

    -- The same nb._on_ws_message shape init.lua:165 builds — op/payload
    -- unwrap, then ws_handlers.dispatch — plus a local kernel-ready latch the
    -- cases below poll through t.eventually.
    local kernel_ready = false
    nb._on_ws_message = function(msg)
      local op = msg.op or msg.name
      local payload = (type(msg.data) == "table" and msg.data) or msg
      if op == "kernel-ready" then kernel_ready = true end
      ws_handlers.dispatch(op, payload, { nb = nb, bufnr = bufnr, raw = msg })
    end

    fn({
      nb = nb,
      bufnr = bufnr,
      filepath = filepath,
      kernel_ready = function() return kernel_ready end,
      reset_kernel_ready = function() kernel_ready = false end,
    })
  end)

  pcall(server.stop, filepath)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  pcall(vim.fn.delete, tmp_dir, "rf")
  config.options = prev_config

  if not ok then error(err, 0) end
end

-- The startup chain server.lua's own start_and_connect runs, spelled out
-- with t.eventually instead of the poll_until/vim.defer_fn callbacks
-- production uses — reusing the same test seams
-- (M._wait_for_server/M._fetch_server_token) tests/record_transcripts.lua
-- (T1) established for exactly this purpose, so a future drift in the real
-- startup chain can't silently diverge from what this suite waits on.
-- `opts.auto_run` is forwarded to server.instantiate — false registers the
-- notebook's cells without executing them, for the "run one cell
-- explicitly" case below.
local function start_and_wait(ctx, opts)
  opts = opts or {}
  local filepath = ctx.filepath

  local srv = server.start(filepath, nil, ctx.nb._on_ws_message)
  t.ok(srv, "server.start failed for " .. filepath)

  local health_ok = false
  server._wait_for_server(srv, 15000, function(ready) health_ok = ready end)
  t.eventually(function() return health_ok end, 15000, "marimo server did not become healthy")

  local token = nil
  server._fetch_server_token(srv.port, filepath, function(tok) token = tok end)
  t.eventually(function() return token ~= nil end, 5000, "could not fetch skew-protection token")
  srv.server_token = token

  server.connect_ws(filepath, ctx.nb._on_ws_message)
  t.eventually(function() return srv.ws_connected == true end, 5000, "WS did not connect")

  server.instantiate(filepath, nil, { auto_run = opts.auto_run })
  t.eventually(ctx.kernel_ready, 15000, "kernel-ready never arrived")

  ctx.srv = srv
  return srv
end

-- ── scenarios ─────────────────────────────────────────────────────────────

t.case("e2e: attach — server starts, WS connects, kernel-ready arrives", function()
  with_notebook("basic_run", function(ctx)
    local srv = start_and_wait(ctx, { auto_run = false })
    t.ok(server.is_running(ctx.filepath), "server.is_running is true after attach")
    t.ok(srv.ws_connected, "srv.ws_connected is true after attach")
    t.ok(ctx.kernel_ready(), "kernel-ready arrived")
  end)
end)

t.case("e2e: run — running one cell eventually renders its output", function()
  with_notebook("basic_run", function(ctx)
    start_and_wait(ctx, { auto_run = false })

    -- basic_run.py cell 1: `x = 1 + 1; x` -> output "2".
    local cell1 = ctx.nb.cells[1]
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    actions.run_cell_at_cursor(ctx.bufnr, ctx.nb)

    t.eventually(function()
      return has_number(cell_output_text(ctx.bufnr, cell1), 2)
    end, 15000, "cell 1 output never rendered '2'")
  end)
end)

t.case("e2e: edit + save + re-run updates the output", function()
  with_notebook("edit_rerun", function(ctx)
    start_and_wait(ctx, { auto_run = true })

    -- edit_rerun.py cell 1: `n = 1; n` -> output "1" on the initial run.
    local cell = ctx.nb.cells[1]
    t.eventually(function()
      return has_number(cell_output_text(ctx.bufnr, cell), 1)
    end, 15000, "initial run never rendered '1'")

    -- Edit the buffer text exactly like a user typing, save through the
    -- real BufWriteCmd target (sync.write_to_file — this is what arms
    -- marimo's --watch reload), then explicitly re-run so the new code
    -- actually executes. sync.write_to_file flushes pending on_bytes
    -- deltas internally before reading cell offsets (see
    -- tests/record_transcripts.lua's edit_rerun action for the same
    -- sequencing), so no separate flush is needed here.
    vim.api.nvim_buf_set_lines(ctx.bufnr, cell.start_row, cell.end_row + 1, false, { "n = 2", "n" })
    sync.write_to_file(ctx.nb)
    actions.run_all_cells(ctx.bufnr, ctx.nb)

    t.eventually(function()
      return has_number(cell_output_text(ctx.bufnr, cell), 2)
    end, 15000, "edited + re-run cell never rendered '2'")
  end)
end)

t.case("e2e: widget value set → dependent cell re-renders", function()
  with_notebook("widgets", function(ctx)
    start_and_wait(ctx, { auto_run = true })

    -- widgets.py: cell 2 is `slider = mo.ui.slider(0, 10, value=5, ...)`,
    -- cell 3 is `doubled = slider.value * 2` -> 10 initially, 16 after the
    -- slider is set to 8.
    local slider_cell = ctx.nb.cells[2]
    local doubled_cell = ctx.nb.cells[3]

    t.eventually(function()
      return has_number(cell_output_text(ctx.bufnr, doubled_cell), 10)
    end, 15000, "initial slider value (5) never produced doubled=10")

    -- The slider's object-id is populated by the real output.render the
    -- instantiate above already triggered (via ws_handlers.dispatch's
    -- cell-op handler) — same registry lookup the widget-picker keymaps use.
    local reg
    t.eventually(function()
      reg = widgets.list_for_cell(ctx.bufnr, slider_cell.id)
      return reg[1] ~= nil
    end, 15000, "slider widget never registered")
    local object_id = reg[1].object_id

    local set_ok = nil
    widgets.set_value(ctx.filepath, object_id, 8, function(ok) set_ok = ok end)
    t.eventually(function() return set_ok ~= nil end, 5000, "set_value request never completed")
    t.ok(set_ok, "set_value POST succeeded")

    t.eventually(function()
      return has_number(cell_output_text(ctx.bufnr, doubled_cell), 16)
    end, 15000, "dependent cell never re-rendered to 16 after the widget change")
  end)
end)

t.case("e2e: disconnect/reconnect — killing the WS job and resyncing recovers", function()
  with_notebook("basic_run", function(ctx)
    local srv = start_and_wait(ctx, { auto_run = true })
    local cell1 = ctx.nb.cells[1]

    t.eventually(function()
      return has_number(cell_output_text(ctx.bufnr, cell1), 2)
    end, 15000, "initial run never rendered '2'")

    -- Kill ws_client.py directly (not server.release_ws, which sets
    -- browser_active for the intentional browser-handoff path — a
    -- different scenario). This is what output.handle_cell_op's self-heal
    -- (plan-refinement F5.2/F5.4) exists to recover from: a WS that just
    -- dies out from under us.
    local ws_job_id = srv.ws_job_id
    t.ok(ws_job_id, "WS job is running before kill")
    vim.fn.jobstop(ws_job_id)
    t.eventually(function() return srv.ws_connected == false end, 5000,
      "srv.ws_connected never flipped false after killing the WS job")

    ctx.reset_kernel_ready()
    t.ok(server.resync_ws(ctx.filepath), "resync_ws dispatched a reconnect")
    t.eventually(function() return srv.ws_connected == true end, 10000,
      "resync did not reconnect the WS")

    -- Discovered empirically (not assumed from server.lua's resync_ws
    -- comment, which describes the *kiosk self-heal after a desync* case):
    -- a plain reconnect to a session marimo never dropped server-side does
    -- NOT replay kernel-ready — it sends a payload-less "reconnected" op
    -- instead (now a registered no-op in ws_handlers.lua, found by this
    -- case). Our nb.cell_by_id map and already-rendered outputs are still
    -- correct as-is here, so there is nothing to re-key or redraw; the real
    -- proof of recovery is the next paragraph, a fresh round trip actually
    -- completing over the new WS connection.
    t.ok(not ctx.kernel_ready(), "sanity: this reconnect path does not replay kernel-ready")

    -- Prove the reconnected WS is actually live end-to-end, not just
    -- flagged connected: run cell 1 again and watch a fresh queued -> idle
    -- round trip land through it. run_cell_at_cursor sets "queued"
    -- synchronously before the HTTP POST even returns, so by the time
    -- t.eventually starts polling the status is genuinely mid-flight.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    actions.run_cell_at_cursor(ctx.bufnr, ctx.nb)
    t.eventually(function() return cell1.status == "idle" end, 15000,
      "cell did not complete a run over the reconnected WS")
  end)
end)

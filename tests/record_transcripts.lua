-- neo-marimo WS session recorder (T1).
--
-- Starts a real marimo kernel exactly the way the plugin does (server.lua's
-- own M.start / M.connect_ws / actions.lua's run/save paths), drives a
-- scripted action list per scenario, and records every raw JSON line
-- ws_client.py emits to tests/transcripts/<marimo major.minor>/<scenario>.jsonl
-- — the raw material T2's replay layer will feed back through
-- server._decode_ws_line + ws_handlers.dispatch. See docs/plan-testing.md T1.
--
-- Usage (needs a marimo-equipped python; mirrors capture_fixtures.py):
--   NEO_MARIMO_TEST_PYTHON=/path/to/python nvim -l tests/record_transcripts.lua [scenario ...]
-- `make transcripts` wires NEO_MARIMO_TEST_PYTHON to the same default as
-- `make fixtures`/`make test`.
--
-- Deviation from the plan's suggested python recorder (tests/record_transcripts.py
-- driving actions over raw HTTP): this is an nvim -l Lua recorder instead —
-- the plan's own explicitly permitted alternative. Reasoning is recorded in
-- docs/plan-testing.md under T1; short version: reimplementing marimo's
-- start/health/token/instantiate/save/rekey choreography from scratch in
-- Python would duplicate a lot of already-battle-tested logic in server.lua,
-- sync.lua, actions.lua and ws_handlers.lua (port selection, skew-token
-- fetch, the save→watch→update-cell-ids rekey dance, widget object-id
-- lookup...). Driving the SAME production code paths directly is less code,
-- and — as a bonus — every action below is byte-for-byte what a keymap
-- press does, so a transcript actually reflects production, not a
-- hand-rolled approximation of it.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":h:h")

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua", -- tests/corpus.lua, for `make transcripts CORPUS=<name>` (T7)
  package.path,
}, ";")

local RAW_PYTHON = os.getenv("NEO_MARIMO_TEST_PYTHON")
if not RAW_PYTHON or RAW_PYTHON == "" then
  io.write("record_transcripts: NEO_MARIMO_TEST_PYTHON is not set (see `make transcripts`).\n")
  os.exit(1)
end
local PYTHON = vim.fn.expand(RAW_PYTHON)

if vim.fn.executable(PYTHON) ~= 1
  or vim.system({ PYTHON, "-c", "import marimo" }):wait().code ~= 0
then
  io.write("record_transcripts: " .. PYTHON .. " has no marimo installed — aborting.\n")
  os.exit(1)
end

-- python_path (bridge.py parse/generate) and marimo_cmd (the actual kernel
-- server executable) are separate config knobs — config.lua's own default
-- for marimo_cmd points at the maintainer's personal pyenv env, which is
-- almost certainly NOT the env NEO_MARIMO_TEST_PYTHON points to. Using the
-- sibling `marimo` binary in PYTHON's own bin/ directory is the only way to
-- guarantee the server we spawn is the same install bridge.py just parsed
-- against (mismatched envs previously produced a very confusing recording:
-- an "Update available 0.19.4 → 0.23.16" alert sourced from an entirely
-- different marimo, and 0.23-shaped ops like "notebook-document-transaction"
-- that 0.19 never sends).
local MARIMO_CMD = vim.fn.fnamemodify(PYTHON, ":h") .. "/marimo"
if vim.fn.executable(MARIMO_CMD) ~= 1 then
  io.write("record_transcripts: no `marimo` executable next to " .. PYTHON .. " (looked for " .. MARIMO_CMD .. ").\n")
  os.exit(1)
end

-- Pin Python's hash seed before spawning anything. marimo's static analysis
-- of a cell walks `set`s of assigned/used names (e.g. to build the
-- "variables" / "declared_by" broadcasts) — with the interpreter's default
-- *randomized* hash seed, iterating one of those sets returns a different
-- order every process run, which showed up as tests/scenarios/rich_output.py
-- (several names bound in one cell) reordering its "variables" op between
-- two otherwise-identical recordings. `--headless`'s subprocess inherits
-- the environment (vim.fn.jobstart's default clear_env=false), so setting
-- this here, before server.start() below, is enough — no server.lua change
-- needed. The seed value (0) is arbitrary; only "fixed" matters.
vim.fn.setenv("PYTHONHASHSEED", "0")

local config = require("neo-marimo.config")
config.setup({ python_path = PYTHON, marimo_cmd = MARIMO_CMD })

local parser = require("neo-marimo.parser")
local notebook = require("neo-marimo.notebook")
local buffer = require("neo-marimo.buffer")
local server = require("neo-marimo.server")
local actions = require("neo-marimo.actions")
local sync = require("neo-marimo.sync")
local widgets = require("neo-marimo.widgets")
local ws_handlers = require("neo-marimo.ws_handlers")

local marimo_version = vim.trim(
  vim.system({ PYTHON, "-c", "import marimo; print(marimo.__version__)" }, { text = true }):wait().stdout or ""
)
-- Fixture-versioning precedent (tests/fixtures/<major.minor>/, capture_fixtures.py).
local VERSION_DIR = marimo_version:match("^(%d+%.%d+)") or marimo_version
local OUT_DIR = root .. "/tests/transcripts/" .. VERSION_DIR
vim.fn.mkdir(OUT_DIR, "p")

local SCENARIOS_DIR = root .. "/tests/scenarios"

-- ── generic (pattern-based) normalization rules ─────────────────────────────
--
-- Kept in one table, same discipline as tests/helpers.lua's H.SCRUB_RULES —
-- a separate table by design (T1 normalizes raw JSON transcripts at record
-- time; T0 normalizes rendered buffer/extmark state), but reusing the same
-- placeholder spelling (<port>, <tmp-path>, <duration>...) so a human
-- reading either kind of golden isn't learning two vocabularies.
-- macOS temp dirs. Applied BEFORE cell-id substitution (see normalize()
-- below), not just lumped into PATTERN_RULES with everything else: a
-- traceback path like "/var/folders/.../marimo_<pid>/__marimo__cell_<id>_.py"
-- contains a real cell id as a substring, and this pattern's char class
-- doesn't include "<"/">" — running it AFTER cell-id substitution would stop
-- the greedy match right at the inserted placeholder's "<", leaving a
-- half-scrubbed "<tmp-path><cell-2>_.py" instead of one clean <tmp-path>.
-- Catches the whole volatile path in one shot either way, including pieces
-- a value-substitution can't know in advance (the per-pid directory name).
local TMP_PATH_RULES = {
  { name = "tmp_paths_bsd", pattern = "/var/folders/[%w%-%._/]+", repl = "<tmp-path>" },
  { name = "tmp_paths_plain", pattern = "/tmp/[%w%-%._/]+", repl = "<tmp-path>" },
}

local PATTERN_RULES = {
  -- Standard 8-4-4-4-12 hex UUIDs: marimo mints a fresh one per run
  -- (_messaging/context.py's run_id_context) and per widget-render
  -- (the `random-id` attribute on <marimo-ui-element>) — both genuinely
  -- random (uuid4()), not derived from the seeded cell-id generator below.
  { name = "uuid", pattern = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x", repl = "<uuid>" },
  -- Wall-clock epoch floats on every cell-op ("timestamp": 1785904805.5337).
  -- Replaced with a bare 0 (not a string) so the line stays valid JSON with
  -- the same field *type* a future consumer might come to depend on.
  { name = "epoch_timestamp", pattern = '"timestamp":%s*[%d]+%.[%d]+', repl = '"timestamp": 0' },
  -- Port: ws_client.py's own "neo_marimo_connected" line echoes it as a bare
  -- JSON *number* field (`"port": 2718`, no quotes) — context-anchored on
  -- the field name so the replacement can safely add quotes (turning it
  -- into a string) without either breaking JSON syntax or risking a blind
  -- digit-substring match inside an unrelated number elsewhere on the line.
  { name = "port_field", pattern = '"port":%s*%d+', repl = '"port": "<port>"' },
  -- Defensive: host:port pairs, in case a future op embeds a URL (matches
  -- tests/helpers.lua's H.SCRUB_RULES spelling for the same concept).
  { name = "host_port", pattern = "(127%.0%.0%.1):%d+", repl = "%1:<port>" },
  { name = "localhost_port", pattern = "(localhost):%d+", repl = "%1:<port>" },
  -- Generic dotted-quad:port, in case server.host is ever something other
  -- than 127.0.0.1/localhost (H.SCRUB_RULES' ip_port future-proofing).
  { name = "ip_port", pattern = "(%d+%.%d+%.%d+%.%d+):%d+", repl = "%1:<port>" },
  -- Python's default object repr() for anything without a custom __repr__
  -- (a matplotlib Figure/Axes, e.g. rich_output.py's `fig`/`ax` variables)
  -- is "<ClassName object at 0x...>" — the address is the object's id(),
  -- genuinely different every process run (ASLR), independent of the
  -- PYTHONHASHSEED pin above (that fixes iteration ORDER, not addresses).
  --
  -- Anchored on the literal "at 0x" Python always emits right before the
  -- address (rather than a bare "0x%x+"), found the hard way (T2, see
  -- docs/plan-testing.md): a base64-encoded image is long enough that the
  -- two literal characters "0x" followed by hex-looking base64 digits show
  -- up by pure chance dozens of times inside rich_output.py's plot — an
  -- unanchored pattern quietly mangled the payload into invalid base64
  -- every recording, which only surfaced once T2 tried to actually decode
  -- and render it. base64's own alphabet has no literal " at " substring
  -- for this to collide with.
  { name = "py_object_addr", pattern = "at 0x%x+", repl = "at <hex-addr>" },
}

-- ── recording one scenario ───────────────────────────────────────────────

-- Poll the event loop (no predicate — jobstart callbacks are event-loop
-- driven) until `state.last_msg_at` hasn't moved for `quiet_ms`, or bail
-- after `max_ms`. This is the T1 analogue of actions/e2e's `t.eventually`:
-- a scenario's actions are considered settled once the kernel stops
-- talking, not on a fixed sleep (marimo's own timing varies with cell
-- complexity — see rich_output.py's deliberately slow plot).
local function wait_quiescent(state, quiet_ms, max_ms)
  -- Restart the silence window from right now. Without this, a second
  -- action fired shortly after the first one's quiescence wait already
  -- returned would see a `last_msg_at` that's already >= quiet_ms in the
  -- past (nothing happened between the two actions either) and report
  -- "quiescent" on its very first check — before the new action's own
  -- POST has even left curl, let alone before the kernel replied. That
  -- silently truncated every action after the first one's messages.
  state.last_msg_at = vim.uv.hrtime() / 1e6
  local elapsed = 0
  local interval = 100
  while elapsed < max_ms do
    if (vim.uv.hrtime() / 1e6) - state.last_msg_at >= quiet_ms then return true end
    vim.wait(interval)
    elapsed = elapsed + interval
  end
  return false
end

-- Read a scenario .py and copy it to a throwaway path. Scenarios must never
-- be mutated in place — edit_rerun.py's action list rewrites cell code
-- mid-recording, and tests/scenarios/*.py is committed source, not scratch
-- state.
local function copy_scenario(name)
  local src_path = SCENARIOS_DIR .. "/" .. name .. ".py"
  local f = assert(io.open(src_path, "r"), "missing scenario: " .. src_path)
  local content = f:read("*a")
  f:close()

  local tmp_dir = vim.fn.tempname()
  vim.fn.mkdir(tmp_dir, "p")
  local tmp_path = tmp_dir .. "/" .. name .. ".py"
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  vim.fn.writefile(lines, tmp_path)
  return tmp_path
end

-- Build a real notebook + real "marimo://" buffer for `filepath` — the same
-- notebook.new + buffer.create + buffer.attach_change_tracking wiring
-- init.lua's M.attach uses (and tests/helpers.lua's H.make_notebook, for the
-- synthetic-notebook case). A real buffer (not a bare scratch one) matters
-- here: ws_handlers.dispatch's cell-op/output.render path indexes cell
-- start_row/end_row into it, and edit_rerun's action edits real buffer text.
local function build_notebook(filepath)
  local data = parser.parse_file(filepath, PYTHON)
  local nb = notebook.new(filepath, data)
  local bufnr = buffer.create(nb, nil)
  buffer.attach_change_tracking(bufnr, nb)
  return nb, bufnr
end

-- One JSON object per line ({"__action__": ...} interleaved with the raw
-- marimo messages it triggered) — readable, and a stable marker for T2's
-- replay layer to split the transcript into per-action segments.
--
-- Built field-by-field with `extra`'s keys sorted, rather than
-- `vim.json.encode` on the whole merged table directly: Lua tables have no
-- defined iteration order, so encoding a table with >1 key can (and did,
-- empirically — this was the first thing the double-run byte-compare
-- caught) serialize its keys in a different order on different process
-- runs. __action__ always comes first for readability.
local function action_marker(action, extra)
  local keys = {}
  for k in pairs(extra or {}) do table.insert(keys, k) end
  table.sort(keys)
  local parts = { '"__action__":' .. vim.json.encode(action) }
  for _, k in ipairs(keys) do
    table.insert(parts, vim.json.encode(k) .. ":" .. vim.json.encode(extra[k]))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Record one scenario. `run_actions(ctx)` drives the scripted action list;
-- `ctx` = { nb, bufnr, filepath, srv, emit_action, run_all, wait_quiescent }.
-- `opts.copy` (default copy_scenario) and `opts.out_dir` (default OUT_DIR)
-- let the T7 corpus recorder below reuse this whole choreography against
-- tests/corpus/*.py and a separate tests/corpus/transcripts/ output tree,
-- instead of duplicating server-start/health/token/WS-connect/instantiate.
local function record_scenario(name, run_actions, opts)
  opts = opts or {}
  local copy = opts.copy or copy_scenario
  local out_dir = opts.out_dir or OUT_DIR

  io.write("recording " .. name .. " ...\n")

  local filepath = copy(name)
  local nb, bufnr = build_notebook(filepath)

  -- ── capture + normalization state (per scenario — fresh mapping) ──────
  local out_lines = {}
  local state = { last_msg_at = vim.uv.hrtime() / 1e6 }
  -- Cell ids: numbered by first appearance ON THE WIRE, checked against
  -- `raw_line` rather than just "is this nb.cells[i].id now". Before
  -- rekey_cells_from_server (ws_handlers.lua) replaces our LOCALLY-minted
  -- ids with the server's real ones on kernel-ready, nb.cells already holds
  -- throwaway random ids from cell.new()'s generate_cell_id() fallback (the
  -- scenario .py files carry no `# id:` comments) — those never touch the
  -- wire, but harvesting them anyway on the earlier neo_marimo_connected
  -- line burned <cell-1>/<cell-2> on ids nobody would ever see, so
  -- kernel-ready's real ids started at <cell-3>. Gating on "does this raw
  -- line actually mention this id" ties numbering to what a human reading
  -- the transcript encounters, and skips the pre-rekey ids entirely (they
  -- never satisfy the check).
  local id_order, id_map = {}, {}
  local function harvest_cell_ids(raw_line)
    for _, cell in ipairs(nb.cells) do
      if cell.id and not id_map[cell.id] and raw_line:find(cell.id, 1, true) then
        table.insert(id_order, cell.id)
        id_map[cell.id] = "<cell-" .. #id_order .. ">"
      end
    end
  end

  -- Literal (exact-value) substitutions, filled in once the server/WS are
  -- up — session id, port, skew token, and this recording's own throwaway
  -- filepath are all known verbatim, which is safer than pattern-matching
  -- them (no risk of a coincidental collision with real notebook content).
  local literal_rules = {}

  local function normalize(raw_line)
    local s = raw_line
    for _, rule in ipairs(literal_rules) do
      s = s:gsub(vim.pesc(rule.value), rule.placeholder)
    end
    -- Tmp paths before cell ids — see TMP_PATH_RULES' comment above for why
    -- the order matters.
    for _, rule in ipairs(TMP_PATH_RULES) do
      s = s:gsub(rule.pattern, rule.repl)
    end
    for _, real_id in ipairs(id_order) do
      s = s:gsub(vim.pesc(real_id), id_map[real_id])
    end
    for _, rule in ipairs(PATTERN_RULES) do
      s = s:gsub(rule.pattern, rule.repl)
    end
    return s
  end

  -- Tee point: server._decode_ws_line is the one place a COMPLETE,
  -- reassembled JSON line from ws_client.py's stdout is available (see
  -- server.lua's M._reassemble_stdout why-comment — the chunked-stdout
  -- bug this whole scenario corpus exists partly to guard against). We
  -- wrap it instead of `on_message` so we (a) see the exact raw bytes
  -- before anything mutates them, and (b) can run the real
  -- ws_handlers.dispatch ourselves, synchronously, right here — giving
  -- deterministic ordering against the action script below instead of
  -- racing connect_ws's own vim.schedule-deferred forwarding.
  local ORIG_DECODE = server._decode_ws_line
  server._decode_ws_line = function(line)
    state.last_msg_at = vim.uv.hrtime() / 1e6
    local msg, err = ORIG_DECODE(line)
    if not msg then return msg, err end

    local op = msg.op or msg.name
    -- "alert" is a CLI update-nag ("Update available X → Y"), not notebook
    -- state — marimo._cli.upgrade hits a real network endpoint (pypi/
    -- marimo.io) and the "latest version" it reports changes over time
    -- independent of anything this suite controls, so recording it would
    -- make goldens flake both on network availability and on the
    -- outside world releasing a new marimo version. Drop it entirely
    -- rather than try to scrub a moving target.
    if op == "alert" then return msg, err end

    local payload = (type(msg.data) == "table" and msg.data) or msg
    pcall(ws_handlers.dispatch, op, payload, { nb = nb, bufnr = bufnr, raw = msg })

    harvest_cell_ids(line)
    table.insert(out_lines, normalize(line))
    return msg, err
  end

  -- ── start the real server + WS, exactly like server.lua's own chain ───
  local srv = server.start(filepath, nil, function() end)
  if not srv then
    io.write("  FAILED to start marimo server for " .. name .. "\n")
    server._decode_ws_line = ORIG_DECODE
    return false
  end

  -- Reuse server.lua's own health-poll / token-fetch (exposed as
  -- M._wait_for_server / M._fetch_server_token specifically for this
  -- recorder) instead of hand-rolled curl calls — a second implementation
  -- of "is the server up" / "what's the skew token" is exactly the kind of
  -- drift-from-production this recorder exists to avoid (and server.lua's
  -- own url_encode, used internally by _fetch_server_token, escapes `/`
  -- where vim.uri_encode doesn't — this only worked before because scratch
  -- tmp paths happened not to need it).
  local health_ok = false
  do
    local done = false
    server._wait_for_server(srv, 10000, function(ready)
      health_ok = ready
      done = true
    end)
    vim.wait(12000, function() return done end, 50)
  end
  if not health_ok then
    io.write("  FAILED: marimo server did not become healthy for " .. name .. "\n")
    server.stop(filepath)
    server._decode_ws_line = ORIG_DECODE
    return false
  end

  local token = nil
  do
    local done = false
    server._fetch_server_token(srv.port, filepath, function(t)
      token = t
      done = true
    end)
    vim.wait(5000, function() return done end, 50)
  end
  if not token then
    io.write("  FAILED: could not fetch skew-protection token for " .. name .. "\n")
    server.stop(filepath)
    server._decode_ws_line = ORIG_DECODE
    return false
  end
  srv.server_token = token

  -- Literal substitutions are safe to fill in now — every value is known
  -- verbatim. Longest-first isn't needed (these don't overlap), but
  -- filepath is deliberately checked before the generic /tmp pattern rule
  -- runs so the WHOLE path collapses to one placeholder instead of a
  -- <tmp-path> with a dangling "/basic_run.py" tail.
  -- Port is deliberately NOT a literal substitution: it's a bare JSON
  -- *number* ("port": 2718, no quotes), so replacing the digits with an
  -- unquoted "<port>" token breaks the line as JSON, and a blind digit-
  -- string substring replace risks matching inside an unrelated larger
  -- number (a timestamp, another id) since literal rules run before the
  -- pattern-based timestamp/uuid rules below. It's handled as a
  -- context-anchored entry in PATTERN_RULES instead (see "port_field").
  literal_rules = {
    { value = filepath, placeholder = "<notebook-path>" },
    { value = srv.session_id, placeholder = "<session-id>" },
    { value = srv.server_token, placeholder = "<server-token>" },
  }

  server.connect_ws(filepath, function() end)

  do
    local elapsed = 0
    while elapsed < 5000 and not srv.ws_connected do
      vim.wait(100)
      elapsed = elapsed + 100
    end
    if not srv.ws_connected then
      io.write("  FAILED: WS did not connect for " .. name .. "\n")
      server.stop(filepath)
      server._decode_ws_line = ORIG_DECODE
      return false
    end
  end

  local ctx = {
    nb = nb,
    bufnr = bufnr,
    filepath = filepath,
    srv = srv,
    -- Routed through the same normalize() every WS line gets: an action's
    -- `extra` fields can carry real (pre-normalization) values a caller
    -- read straight off the live notebook/widget-registry state (e.g. a
    -- widget's real object-id) — this ties them to the same placeholders
    -- (<cell-N>, <tmp-path>, ...) their surrounding WS lines already use,
    -- instead of the caller having to hand-guess the placeholder text.
    emit_action = function(action, extra)
      table.insert(out_lines, normalize(action_marker(action, extra)))
    end,
    run_all = function()
      actions.run_all_cells(bufnr, nb)
    end,
    wait_quiescent = function(quiet_ms, max_ms)
      return wait_quiescent(state, quiet_ms or 2000, max_ms or 20000)
    end,
  }

  -- Initial instantiate (registers + runs every cell) mirrors what
  -- server.lua's start_headless/start_and_open always do before any
  -- user-triggered action — the same "first thing that happens on a real
  -- attach" every scenario needs as its opening beat.
  ctx.emit_action("instantiate")
  server.instantiate(filepath)
  ctx.wait_quiescent()

  local ok, err = pcall(run_actions, ctx)
  if not ok then
    io.write("  scenario actions FAILED for " .. name .. ": " .. tostring(err) .. "\n")
  end

  ctx.wait_quiescent(2000, 5000)

  server.stop(filepath)
  server._decode_ws_line = ORIG_DECODE

  vim.fn.mkdir(out_dir, "p")
  local out_path = out_dir .. "/" .. name .. ".jsonl"
  local f = assert(io.open(out_path, "w"))
  f:write(table.concat(out_lines, "\n"))
  if #out_lines > 0 then f:write("\n") end
  f:close()
  io.write("  wrote " .. out_path .. " (" .. #out_lines .. " lines)\n")
  return ok
end

-- ── scenario action scripts ──────────────────────────────────────────────

local SCENARIOS = {}

SCENARIOS.basic_run = function(ctx)
  -- instantiate (above) already ran both cells; nothing else to script —
  -- this scenario's whole point is the plain two-dependent-cells baseline.
end

SCENARIOS.widgets = function(ctx)
  -- Move the slider. widgets.lua's registry is populated by the real
  -- output.render the instantiate above already triggered (via
  -- ws_handlers.dispatch's cell-op handler), so the object-id is already
  -- there to look up — exactly how the widget picker keymaps find it.
  local slider_cell = ctx.nb.cells[2]
  local reg = widgets.list_for_cell(ctx.bufnr, slider_cell.id)
  if not reg[1] then
    error("widgets scenario: slider not found in registry after instantiate")
  end
  local object_id = reg[1].object_id

  -- Real object_id in the marker (normalize() scrubs it like any WS line —
  -- see ctx.emit_action above), not a hand-guessed placeholder string.
  ctx.emit_action("set-widget-value", { object_id = object_id, value = 8 })
  widgets.set_value(ctx.filepath, object_id, 8, function() end)
  ctx.wait_quiescent()
end

SCENARIOS.error_cell = function(ctx)
  -- instantiate (above) already ran the raising cell; nothing else to
  -- script — this scenario's whole point is the error-output payload shape.
end

SCENARIOS.rich_output = function(ctx)
  -- instantiate (above) already ran the dataframe + matplotlib cells; the
  -- big plot is what exercises the chunked-stdout reassembly path.
end

SCENARIOS.edit_rerun = function(ctx)
  local nb, bufnr = ctx.nb, ctx.bufnr
  local cell = nb.cells[1]

  ctx.emit_action("edit-and-save", { cell = "<cell-1>", new_code = "n = 2\nn" })
  -- Edit the buffer text exactly like a user typing, then save through the
  -- real BufWriteCmd target (sync.write_to_file) — this is what arms
  -- marimo's --watch reload, which broadcasts update-cell-ids /
  -- update-cell-codes (or "reload" on 0.23+) and is what the scenario
  -- exists to exercise (docs/plan-testing.md T1's edit_rerun.py goal).
  vim.api.nvim_buf_set_lines(bufnr, cell.start_row, cell.end_row + 1, false, { "n = 2", "n" })
  -- sync.write_to_file already flushes pending on_bytes deltas internally
  -- (sync.lua) before reading cell offsets — no separate flush needed here.
  sync.write_to_file(nb)
  ctx.wait_quiescent()

  ctx.emit_action("run-cell")
  ctx.run_all()
  ctx.wait_quiescent()
end

-- ── T7 corpus recording (`make transcripts CORPUS=<name>`) ────────────────
--
-- Reuses record_scenario's whole server-start/health/token/WS-connect/
-- instantiate choreography against tests/corpus/*.py instead of
-- tests/scenarios/*.py — a real third-party notebook has no scripted action
-- list behind it (we don't know its semantics ahead of time), so the run is
-- just "instantiate every cell and let it settle", output goes to a SEPARATE
-- tree (tests/corpus/transcripts/<version>/, gitignored — see
-- tests/corpus.lua's transcript_path doc comment on why corpus recordings
-- aren't committed the way the curated tests/transcripts/ corpus is), and a
-- notebook whose imports this python doesn't have is skipped with a notice
-- rather than let the kernel spawn fail loudly mid-recording
-- (docs/plan-testing.md T7 build step 4's explicit contract — mirrors
-- capture_fixtures.py's own "skip: <lib> not installed" pattern).
local CORPUS_NAME = os.getenv("CORPUS")
if CORPUS_NAME and CORPUS_NAME ~= "" then
  local corpus = require("corpus")
  local corpus_path = corpus.path(CORPUS_NAME)
  if vim.fn.filereadable(corpus_path) ~= 1 then
    io.write("record_transcripts: no such corpus notebook: " .. corpus_path .. "\n")
    os.exit(1)
  end

  local check = vim.system(
    { PYTHON, root .. "/python/bridge.py", "check-imports", corpus_path },
    { text = true }
  ):wait()
  if check.code == 0 then
    local decode_ok, decoded = pcall(vim.json.decode, check.stdout or "")
    if decode_ok and decoded.missing and #decoded.missing > 0 then
      io.write("record_transcripts: " .. CORPUS_NAME .. ": skipped — missing import(s) in "
        .. PYTHON .. ": " .. table.concat(decoded.missing, ", ") .. "\n")
      os.exit(0)
    end
  else
    -- Import-check itself failing (e.g. the notebook doesn't even parse) is
    -- not the same claim as "imports are missing" — don't silently skip on
    -- an unrelated bridge error, let the real recording attempt surface it.
    io.write("record_transcripts: " .. CORPUS_NAME .. ": check-imports failed ("
      .. tostring(check.stderr) .. "), attempting to record anyway\n")
  end

  local function copy_corpus(name)
    local f = assert(io.open(corpus_path, "r"), "missing corpus notebook: " .. corpus_path)
    local content = f:read("*a")
    f:close()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    local tmp_path = tmp_dir .. "/" .. name .. ".py"
    local lines = vim.split(content, "\n", { plain = true })
    if lines[#lines] == "" then table.remove(lines) end
    vim.fn.writefile(lines, tmp_path)
    return tmp_path
  end

  -- No extra action script — record_scenario's own leading `instantiate`
  -- beat (registers + runs every cell) is the whole point here.
  local ok = record_scenario(CORPUS_NAME, function(_ctx) end, {
    copy = copy_corpus,
    out_dir = corpus.dir .. "/transcripts/" .. VERSION_DIR,
  })
  os.exit(ok and 0 or 1)
end

-- ── main ──────────────────────────────────────────────────────────────────

-- Positional CLI args (direct `nvim -l tests/record_transcripts.lua widgets`
-- invocation) win; otherwise fall back to NEO_MARIMO_TEST_FILTER
-- (space-separated for more than one name), which is how `make transcripts
-- FILTER=...` passes it through — see the Makefile's `export
-- NEO_MARIMO_TEST_FILTER` comment for why this is an env var and not a
-- positional recipe argument (a scenario name is never attacker/typo-prone
-- shell-metacharacter content in practice, but the plumbing is shared with
-- tests/run.lua's FILTER, which is — consistency over a one-off exception).
local requested = {}
for i = 1, #(_G.arg or {}) do requested[_G.arg[i]] = true end
if next(requested) == nil then
  local env_filter = os.getenv("NEO_MARIMO_TEST_FILTER")
  if env_filter and env_filter ~= "" then
    for word in env_filter:gmatch("%S+") do requested[word] = true end
  end
end

local names = {}
for name in pairs(SCENARIOS) do
  if next(requested) == nil or requested[name] then
    table.insert(names, name)
  end
end
table.sort(names)

if #names == 0 then
  io.write("record_transcripts: no matching scenarios (requested: "
    .. table.concat(vim.tbl_keys(requested), ", ") .. ")\n")
  os.exit(1)
end

local all_ok = true
for _, name in ipairs(names) do
  local ok = record_scenario(name, SCENARIOS[name])
  all_ok = all_ok and ok
end

os.exit(all_ok and 0 or 1)

-- Shared helpers for the neo-marimo test suite. Loaded by tests/run.lua;
-- spec files require it as `local t = require("helpers")` and register cases
-- with `t.case(name, fn)`.

local H = {}

H.cases = {}

-- Repo root (tests/ lives directly under it). Set by run.lua before specs load.
H.root = nil

-- Name of the t.case currently executing, set by run.lua right before it
-- calls case.fn. t.snapshot reads this to name the exact `make snapshots
-- FILTER=...` invocation that re-selects the failing case (T4) — run.lua's
-- filter matches against case.name (a plain substring check), not the
-- snapshot's own name, and the two aren't always textually related (e.g.
-- output_spec.lua's case names don't literally contain their snapshot
-- names). nil outside of a case (or if run.lua is ever bypassed), in which
-- case t.snapshot falls back to the snapshot name itself.
H._current_case = nil

function H.case(name, fn)
  table.insert(H.cases, { name = name, fn = fn })
end

-- Callbacks run once, after every case has executed, before run.lua prints
-- its final pass/fail tally — for a report that only makes sense as one
-- block once everything is known (T7's "CORPUS GAPS:" summary is the reason
-- this exists: a per-notebook gap line printed inline mid-suite would land
-- wherever tests/spec/corpus_spec.lua happens to sort alphabetically, not at
-- the end a human is actually looking at). Generic on purpose — any future
-- "summarize across every case" report can reuse this instead of growing its
-- own end-of-run hook in run.lua.
H.on_finish = {}

function H.after_all(fn)
  table.insert(H.on_finish, fn)
end

-- ── assertions ────────────────────────────────────────────────────────────

local function fail(msg)
  error(msg, 3)
end

function H.ok(cond, msg)
  if not cond then fail(msg or "expected truthy value") end
end

function H.eq(got, want, msg)
  if not vim.deep_equal(got, want) then
    fail((msg and msg .. ": " or "")
      .. "expected " .. vim.inspect(want)
      .. "\n     got " .. vim.inspect(got))
  end
end

function H.match(s, pat, msg)
  if type(s) ~= "string" or not s:find(pat) then
    fail((msg and msg .. ": " or "")
      .. "expected match for " .. vim.inspect(pat)
      .. " in " .. vim.inspect(type(s) == "string" and s:sub(1, 200) or s))
  end
end

function H.no_match(s, pat, msg)
  if type(s) == "string" and s:find(pat) then
    fail((msg and msg .. ": " or "")
      .. "expected NO match for " .. vim.inspect(pat)
      .. " in " .. vim.inspect(s:sub(1, 200)))
  end
end

-- Poll `fn()` on the real event loop until it returns truthy, or fail after
-- `timeout_ms` (default 5000). Backs the E2E layer (T3, tests/spec/e2e_spec.lua):
-- a real marimo kernel's timing varies with machine load and cell complexity,
-- so a fixed `vim.uv.sleep`/`vim.wait(N)` is either flaky (too short) or
-- wastes wall-clock on every case (too long, "just in case"). Every E2E
-- assertion goes through this instead of a bare sleep.
--
-- `fn` is pcall'd on each poll: a predicate that reads not-yet-created state
-- (an extmark id that doesn't exist until the first render, a table field a
-- WS handler hasn't populated yet) is expected to error transiently while
-- the kernel is still catching up, not to abort the whole wait.
-- The last pcall error is kept and folded into the timeout failure: without
-- it, a predicate that errors on *every* poll (a genuine bug — typo'd field,
-- nil index — not transient not-ready state) is indistinguishable from a
-- slow kernel, and the real error is silently discarded.
function H.eventually(fn, timeout_ms, msg)
  timeout_ms = timeout_ms or 5000
  local last_err
  local ok = vim.wait(timeout_ms, function()
    local success, result = pcall(fn)
    if not success then last_err = result end
    return success and result and true or false
  end, 50)
  if not ok then
    fail((msg or ("condition not met within " .. timeout_ms .. "ms"))
      .. (last_err and ("\n  last predicate error: " .. tostring(last_err)) or ""))
  end
end

-- ── fixtures ──────────────────────────────────────────────────────────────

-- Newest fixture version directory under tests/fixtures (sorted descending,
-- so "0.20" beats "0.19" once captured).
function H.fixture_dir()
  local dirs = vim.fn.glob(H.root .. "/tests/fixtures/*", false, true)
  table.sort(dirs, function(a, b) return a > b end)
  assert(dirs[1], "no fixture directories — run tests/capture_fixtures.py")
  return dirs[1]
end

function H.fixture(name)
  local path = H.fixture_dir() .. "/" .. name .. ".html"
  local f = assert(io.open(path, "r"), "missing fixture: " .. path)
  local s = f:read("*a")
  f:close()
  return s
end

function H.fixture_names()
  local out = {}
  for _, p in ipairs(vim.fn.glob(H.fixture_dir() .. "/*.html", false, true)) do
    table.insert(out, vim.fn.fnamemodify(p, ":t:r"))
  end
  table.sort(out)
  return out
end

-- ── live notebook harness ─────────────────────────────────────────────────

local _nb_counter = 0

-- Build a live notebook from a list of cell code strings: real state table,
-- real marimo:// buffer, real change tracking — the same buffer.create +
-- buffer.attach_change_tracking paths production uses, minus the python
-- parser / server / watcher / LSP. The buffer is made current so cursor and
-- normal-mode commands target it.
--
-- Tests drive edits exactly like a user (nvim_buf_set_lines, :normal!,
-- :normal for buffer-local boundary keymaps, :undo) and call
-- nb._flush_pending() where a keymap action would — the synchronous
-- stand-in for the 300ms debounce.
function H.make_notebook(codes)
  local config = require("neo-marimo.config")
  if not config.options.python_path then
    config.setup({})
  end

  local notebook = require("neo-marimo.notebook")
  local buffer = require("neo-marimo.buffer")
  local keymaps = require("neo-marimo.keymaps")

  _nb_counter = _nb_counter + 1
  local filepath = "/tmp/neo-marimo-test-" .. _nb_counter .. ".py"

  local data = { cells = {} }
  for _, code in ipairs(codes) do
    table.insert(data.cells, { name = "_", code = code })
  end

  local nb = notebook.new(filepath, data)
  local bufnr = buffer.create(nb, nil)
  buffer.attach_change_tracking(bufnr, nb)
  -- Wire the buffer-local boundary-aware keymaps (smart paste, `o`) the
  -- same way production's keymaps.setup does — without this, a test
  -- driving `normal o...` (mapped) would fall through to native `o` and
  -- couldn't exercise the plan-refinement F3.1 boundary rewrite at all.
  keymaps.setup_editing_keymaps(bufnr, nb)
  vim.api.nvim_set_current_buf(bufnr)
  return nb, bufnr
end

-- Close the current undo block. In a headless script there is no user input
-- loop, so consecutive buffer edits all merge into a single undo block and
-- one `:undo` would revert everything since attach. Interactive editing gets
-- a new block per command; tests call this where that boundary would fall
-- (right before the edit they intend to undo).
function H.undo_break()
  vim.cmd("let &undolevels = &undolevels")
end

-- Assert the notebook's offsets form a contiguous cover of the buffer and
-- every cell's code matches its buffer slice — the same invariants the
-- save validator enforces. Call after every mutation in editing tests.
function H.assert_consistent(nb, bufnr, msg)
  local notebook = require("neo-marimo.notebook")
  local ok, errors = notebook.validate_offsets(nb, bufnr)
  if not ok then
    fail((msg or "notebook drifted") .. ": " .. table.concat(errors, "; "))
  end
  for i, cell in ipairs(nb.cells) do
    local slice = vim.api.nvim_buf_get_lines(bufnr, cell.start_row, cell.end_row + 1, false)
    local slice_text = table.concat(slice, "\n")
    if slice_text ~= (cell.code or "") then
      fail((msg or "notebook drifted") .. string.format(
        ": cell[%d] code %s disagrees with buffer rows %d-%d %s",
        i, vim.inspect(cell.code), cell.start_row, cell.end_row,
        vim.inspect(slice_text)))
    end
  end
end

-- ── virt_lines helpers ────────────────────────────────────────────────────

-- Flatten virt_line chunk lists into plain strings, one per line — what the
-- user would see, minus highlights. Most render assertions go through this.
function H.flat_lines(virt_lines)
  local out = {}
  for _, chunks in ipairs(virt_lines or {}) do
    local s = ""
    for _, ch in ipairs(chunks) do s = s .. ch[1] end
    table.insert(out, s)
  end
  return out
end

function H.joined(virt_lines)
  return table.concat(H.flat_lines(virt_lines), "\n")
end

-- ── snapshot testing (T0) ────────────────────────────────────────────────
--
-- t.snapshot(name, text) compares `text` against the checked-in golden at
-- tests/snapshots/<name>.txt:
--   - golden missing, NEO_MARIMO_UPDATE_SNAPSHOTS unset  -> fail, name the
--     fix (`make snapshots`).
--   - golden missing, NEO_MARIMO_UPDATE_SNAPSHOTS=1       -> write it, pass.
--   - golden present, matches                             -> pass, silent.
--   - golden present, mismatches, env unset                -> fail with a
--     unified diff (vim.diff, nvim 0.11+) and write
--     tests/snapshots/<name>.actual.txt (gitignored) for inspection with
--     any tool.
--   - golden present, mismatches, env=1                    -> overwrite,
--     pass, print "updated".
-- `make snapshots` = `NEO_MARIMO_UPDATE_SNAPSHOTS=1 make test`.

-- Snapshots are compared as text files; normalize to exactly one trailing
-- newline so a caller that forgets (or doesn't forget) a final "\n" doesn't
-- produce a spurious diff against a golden written by a caller that did.
local function ensure_trailing_newline(s)
  if s:sub(-1) ~= "\n" then return s .. "\n" end
  return s
end

-- The exact command that re-runs (only) the currently-executing case with
-- goldens regenerated: FILTER's value must be the *case* name
-- (H._current_case), not the snapshot's own name — run.lua's filter is a
-- plain substring match against case.name, and the two names aren't always
-- textually related. Falls back to the snapshot name if called outside a
-- t.case (shouldn't happen via `make test`, but keeps the message sane for a
-- stray direct call).
--
-- Two escaping steps, in order, both load-bearing — a naive `FILTER="%s"`
-- (the original T4 version) breaks on real case names: snapshot_spec.lua has
-- one containing backticks, and output_spec.lua has one containing a `"`.
--   1. Double any literal "$" in the value. This isn't about the shell at
--      all — it's because GNU Make expands "$" inside a command-line-set
--      variable's value every time it computes that value (verified
--      empirically; see the Makefile's `export NEO_MARIMO_TEST_FILTER`
--      comment), so an unescaped "$" would silently eat characters (e.g.
--      "$HOME" truncating to "OME") no matter how the shell layer is
--      quoted. "$$" is make's own escape for a literal "$" and survives
--      make's expansion intact. No committed case name currently contains
--      "$" — this is defensive, and the one genuinely remaining limitation:
--      a value containing "$" must be typed as "$$" by whoever pastes this,
--      which the printed command below does NOT do for them (see the
--      Makefile comment for why a fully general fix isn't worth the
--      complexity here).
--   2. vim.fn.shellescape the result: wraps in single quotes (escaping any
--      embedded single quote as '\''), which is what actually neutralizes
--      backticks/`"`/`$(...)`/spaces for the shell the human pastes this
--      into — double quotes do NOT neutralize backticks (`` "`cmd`" `` still
--      runs `cmd`), which is exactly what made the original version unsafe.
-- Verified against both real hostile case names (see snapshot_spec.lua's own
-- "accept_command" cases) and empirically against `make snapshots
-- FILTER='...'` end-to-end (docs/plan-testing.md's T4 deviation note).
local function accept_command(name)
  local filter_value = (H._current_case or name):gsub("%$", "$$")
  return "make snapshots FILTER=" .. vim.fn.shellescape(filter_value)
end

function H.snapshot(name, text)
  text = ensure_trailing_newline(text)
  local dir = H.root .. "/tests/snapshots"
  vim.fn.mkdir(dir, "p")
  local golden_path = dir .. "/" .. name .. ".txt"
  local actual_path = dir .. "/" .. name .. ".actual.txt"
  local update = os.getenv("NEO_MARIMO_UPDATE_SNAPSHOTS") == "1"

  local f = io.open(golden_path, "r")
  if not f then
    if not update then
      fail(string.format(
        "missing snapshot '%s' (%s) — run `%s` to create it",
        name, golden_path, accept_command(name)))
    end
    local wf = assert(io.open(golden_path, "w"))
    wf:write(text)
    wf:close()
    io.write("\n  [snapshot] created " .. name .. "\n")
    return
  end
  local golden = f:read("*a")
  f:close()

  if golden == text then
    -- A stale .actual.txt from a previous failing run would otherwise sit
    -- next to a now-passing golden and confuse a human diffing by hand.
    os.remove(actual_path)
    return
  end

  if update then
    local wf = assert(io.open(golden_path, "w"))
    wf:write(text)
    wf:close()
    io.write("\n  [snapshot] updated " .. name .. "\n")
    return
  end

  local af = assert(io.open(actual_path, "w"))
  af:write(text)
  af:close()

  local diff = vim.diff(golden, text, { result_type = "unified", ctxlen = 2 })
  fail(string.format(
    "snapshot '%s' mismatch — actual written to %s\n%s\nrun `%s` to accept this change",
    name, actual_path, diff or "(vim.diff produced no output)", accept_command(name)))
end

-- ── replay layer (T2) ────────────────────────────────────────────────────
--
-- t.replay(name, nb, bufnr, opts) feeds a recorded WS transcript (T1,
-- tests/transcripts/<version>/<name>.jsonl) through the exact decode+dispatch
-- path production uses — server._decode_ws_line then ws_handlers.dispatch —
-- against a real notebook/buffer from t.make_notebook. No server, no kernel,
-- no python: the transcript already IS the kernel's output, byte-for-byte.

-- Newest transcript-version directory wins, mirroring H.fixture_dir.
-- Caveat (shared with H.fixture_dir): the sort is lexicographic, so a
-- two-digit minor breaks it ("0.9" > "0.10"). Fine for 0.19/0.23; switch
-- both to a numeric-aware sort before recording a version where it isn't.
function H.transcript_dir()
  local dirs = vim.fn.glob(H.root .. "/tests/transcripts/*", false, true)
  table.sort(dirs, function(a, b) return a > b end)
  assert(dirs[1], "no transcript directories — run `make transcripts`")
  return dirs[1]
end

function H.transcript_names()
  local out = {}
  for _, p in ipairs(vim.fn.glob(H.transcript_dir() .. "/*.jsonl", false, true)) do
    table.insert(out, vim.fn.fnamemodify(p, ":t:r"))
  end
  table.sort(out)
  return out
end

-- Extract a scenario's cell source straight from tests/scenarios/<name>.py,
-- for building the matching t.make_notebook(codes) a replay dispatches
-- against. NOT a general marimo-cell parser — bridge.py owns that — this
-- only has to handle the 5 committed scenario files, which all use marimo's
-- default 4-space generated indent, one flat body per cell, and end each
-- cell with a bare `return`/`return (...)` line. Verified byte-identical
-- against the committed transcripts' own kernel-ready `codes` field; reach
-- for that field directly (or extend this) if a future scenario needs
-- anything this can't handle (nested defs, multi-line strings, etc).
function H.scenario_codes(name)
  local path = H.root .. "/tests/scenarios/" .. name .. ".py"
  local f = assert(io.open(path, "r"), "missing scenario: " .. path)
  local content = f:read("*a")
  f:close()

  local lines = vim.split(content, "\n", { plain = true })
  local codes = {}
  local i = 1
  while i <= #lines do
    if lines[i]:match("^@app%.cell") then
      i = i + 2 -- skip "@app.cell" and the "def _(...):" signature line
      local body = {}
      while i <= #lines and not lines[i]:match("^    return%f[%A]") do
        table.insert(body, (lines[i]:gsub("^    ", "")))
        i = i + 1
      end
      -- A trailing blank line right before `return` isn't part of the
      -- cell's actual source (marimo's own extraction drops it too).
      while #body > 0 and body[#body] == "" do table.remove(body) end
      table.insert(codes, table.concat(body, "\n"))
      i = i + 1 -- skip the `return` line itself
    else
      i = i + 1
    end
  end
  return codes
end

-- Pump the event loop until scheduled render work has run. output.lua's
-- handle_cell_op defers the actual M.render call via vim.schedule instead of
-- rendering inline (so a burst of cell-ops during a real WS session doesn't
-- redraw mid-burst) — a dispatched cell-op's extmarks don't exist until the
-- loop gets a turn. vim.wait(0) runs exactly one loop iteration, which
-- empirically flushes everything *currently* queued (verified: a callback
-- registered immediately before is visibly run after a single call); loop a
-- few times anyway — cheap (each pass is sub-millisecond when there's
-- nothing left to do) — in case a callback ever enqueues another one, capped
-- by `timeout_ms` as a hard backstop against ever hanging a test on a stuck
-- schedule queue.
function H.drain(timeout_ms)
  timeout_ms = timeout_ms or 500
  local start = vim.uv.hrtime() / 1e6
  for _ = 1, 10 do
    vim.wait(0)
    if (vim.uv.hrtime() / 1e6) - start >= timeout_ms then break end
  end
end

-- Feed tests/transcripts/<newest>/<name>.jsonl through server._decode_ws_line
-- + ws_handlers.dispatch against `nb`/`bufnr` (from t.make_notebook).
--
-- Each transcript line is either an `{"__action__": ...}` marker (T1) or a
-- raw WS message. Markers are counted and (optionally) reported via
-- opts.on_action; everything else is decoded and dispatched exactly the way
-- init.lua's nb._on_ws_message does at the dispatch call site (init.lua:165)
-- — op = msg.op or msg.name, payload = msg.data if it's a table else the
-- whole message, ctx = { nb = nb, bufnr = bufnr, raw = msg }.
--
-- opts.until_action: stop once this many `__action__` markers have been
-- reached (that marker's own messages are NOT replayed), so a caller can
-- snapshot an intermediate state — e.g. edit_rerun's "edited, not yet
-- rerun" beat sits between its 2nd and 3rd markers. nil replays the whole
-- file.
-- opts.on_dispatch(op, payload, ok): called after every non-marker line is
-- decoded and dispatched; `ok` is ws_handlers.dispatch's own return value.
-- Used by the coverage-guard case to tell "no handler for this op" (ok ==
-- false, error count unchanged) apart from "handler threw".
-- opts.on_action(action, extra): called for every `__action__` marker with
-- its action name and the rest of the marker's fields.
-- opts.drain_timeout: forwarded to H.drain after the whole replay.
-- opts.path: replay a transcript at an explicit path instead of looking one
-- up under H.transcript_dir() by `name`. Added for T7's corpus level 3
-- (tests/corpus.lua's own transcript_path, a sibling tree under
-- tests/corpus/transcripts/ — corpus recordings are optional/unstable
-- per-notebook and deliberately not committed alongside the curated T1
-- scenario corpus, see tests/corpus.lua's transcript_path doc comment).
function H.replay(name, nb, bufnr, opts)
  opts = opts or {}
  local server = require("neo-marimo.server")
  local ws_handlers = require("neo-marimo.ws_handlers")

  local path = opts.path or (H.transcript_dir() .. "/" .. name .. ".jsonl")
  local f = assert(io.open(path, "r"), "missing transcript: " .. path)

  local action_count = 0
  for line in f:lines() do
    if line ~= "" then
      local ok_decode, decoded = pcall(vim.json.decode, line)
      if ok_decode and type(decoded) == "table" and decoded.__action__ then
        action_count = action_count + 1
        if opts.until_action and action_count > opts.until_action then
          break
        end
        if opts.on_action then
          local extra = {}
          for k, v in pairs(decoded) do
            if k ~= "__action__" then extra[k] = v end
          end
          opts.on_action(decoded.__action__, extra)
        end
      else
        -- Same decode point production uses (server.lua's dispatch_line
        -- closure inside connect_ws). Replay skips M._reassemble_stdout's
        -- chunk-stitching on purpose: that reassembles ws_client.py's
        -- stdout chunks into one complete line, and a transcript is already
        -- one complete JSON object per line by construction (T1 records
        -- post-reassembly) — reassembling again here would be a no-op at
        -- best and silently wrong if a transcript line ever legitimately
        -- contained an embedded newline.
        local msg = server._decode_ws_line(line)
        if msg then
          local op = msg.op or msg.name
          local payload = (type(msg.data) == "table" and msg.data) or msg
          local ok = ws_handlers.dispatch(op, payload, { nb = nb, bufnr = bufnr, raw = msg })
          if opts.on_dispatch then opts.on_dispatch(op, payload, ok) end
        end
      end
    end
  end
  f:close()

  H.drain(opts.drain_timeout)
end

-- ── render-state serializer (T0) ─────────────────────────────────────────
--
-- t.render_state(bufnr, opts) -> one stable string: buffer lines, then
-- extmarks grouped by namespace *name* (not the raw numeric ns_id, which is
-- a require()-order-dependent counter and would make every snapshot diff on
-- an unrelated module load reorder). Highlight group names are included —
-- they're part of what the user sees. Volatile values (cell ids, tmp paths,
-- ports, durations/timestamps) are scrubbed; see H.SCRUB_RULES to extend.
--
-- CAVEAT: grouping is alphabetical by namespace name, NOT on-screen render
-- order. When ns_border and ns_output virt_lines share an anchor row, the
-- screen interleaving is decided by extmark right_gravity (the e414de6 /
-- F2.1 gravity fix, see output.lua) — this serializer cannot see that, so a
-- gravity regression will NOT show up in a snapshot diff. Cross-namespace
-- ordering keeps its dedicated ns_id=-1 assertions in editing_spec.lua /
-- output_spec.lua; don't convert those to snapshots.
--
-- opts.cell_ids: an ordered list of real cell ids to scrub to <cell-1>,
-- <cell-2>, … in first-seen order within the serialized text. Optional —
-- most of this suite's cells use small deterministic test ids ("ocell1",
-- "test1", …) that never need scrubbing; pass real ids (e.g. nb.cells[i].id
-- from t.make_notebook, which are random per generate_cell_id()) when a
-- snapshot's buffer/notebook was built through that path.

-- Centralized so a newly discovered volatile value is a one-line addition
-- instead of a change to the serializer itself. Patterns use Lua string
-- patterns (not regex); %f[...] frontier patterns give correct word
-- boundaries including at string start/end (the implicit \0 boundary).
H.SCRUB_RULES = {
  -- macOS temp dirs, and the plain /tmp paths this suite's make_notebook()
  -- uses for its throwaway filepath (tests/helpers.lua's _nb_counter makes
  -- even the *name* volatile depending on case-registration order).
  { name = "tmp_paths_bsd", pattern = "/var/folders/[%w%-%._/]+", repl = "<tmp-path>" },
  { name = "tmp_paths_plain", pattern = "/tmp/[%w%-%._/]+", repl = "<tmp-path>" },
  -- host:port pairs (server.lua binds an ephemeral port per run).
  { name = "host_port", pattern = "(://[%w%.%-]+):%d+", repl = "%1:<port>" },
  { name = "localhost_port", pattern = "(localhost):%d+", repl = "%1:<port>" },
  -- Bare ip:port too — server.lua binds 127.0.0.1, which reaches snapshots
  -- without a scheme or "localhost" prefix. Must come after host_port so a
  -- scheme-prefixed URL is already scrubbed before this simpler shape runs.
  { name = "ip_port", pattern = "(%d+%.%d+%.%d+%.%d+):%d+", repl = "%1:<port>" },
  -- ISO-8601 timestamps.
  { name = "iso_timestamp", pattern = "%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[%.%d]*Z?", repl = "<timestamp>" },
  -- Durations like "123ms" / "1.5s". Bounded so plain numbers or this
  -- serializer's own "[row,col]" markers are never touched.
  { name = "duration_ms", pattern = "%f[%d]%d+%.?%d*ms%f[%A]", repl = "<duration>" },
  { name = "duration_s", pattern = "%f[%d]%d+%.?%d*s%f[%A]", repl = "<duration>" },
}

-- Cell ids can't be a static pattern (they're 4 random letters,
-- indistinguishable from any other short word) — the caller must supply the
-- real ids it used. Assign placeholders by each id's first byte-offset in
-- `text`, not by `cell_ids`' own order, so "first-seen" matches what a human
-- reading the diff actually encounters top to bottom.
local function scrub_cell_ids(text, cell_ids)
  if not cell_ids or #cell_ids == 0 then return text end

  local first_pos = {}
  for _, id in ipairs(cell_ids) do
    if first_pos[id] == nil then
      first_pos[id] = text:find(id, 1, true) or false
    end
  end

  local seen = {}
  for id, pos in pairs(first_pos) do
    if pos then table.insert(seen, { id = id, pos = pos }) end
  end
  table.sort(seen, function(a, b) return a.pos < b.pos end)

  for i, entry in ipairs(seen) do
    text = text:gsub(vim.pesc(entry.id), "<cell-" .. i .. ">")
  end
  return text
end

-- Chunks are {text, hl_group} pairs (virt_text's own shape, and each entry
-- of a virt_lines line). Returns the plain concatenated text plus the list
-- of highlight group names encountered, in order.
local function chunks_text_and_hls(chunks)
  local text_parts, hls = {}, {}
  for _, ch in ipairs(chunks or {}) do
    table.insert(text_parts, ch[1] or "")
    local g = ch[2]
    if g then
      table.insert(hls, type(g) == "table" and table.concat(g, ",") or tostring(g))
    end
  end
  return table.concat(text_parts), hls
end

local function hls_suffix(hls)
  if #hls == 0 then return "" end
  return "  hl=[" .. table.concat(hls, ",") .. "]"
end

function H.render_state(bufnr, opts)
  opts = opts or {}
  local out = {}

  table.insert(out, "== buffer ==")
  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    table.insert(out, string.format("%3d| %s", i - 1, line))
  end

  local namespaces = vim.api.nvim_get_namespaces()
  local names = {}
  for name in pairs(namespaces) do table.insert(names, name) end
  table.sort(names)

  for _, name in ipairs(names) do
    local marks = vim.api.nvim_buf_get_extmarks(
      bufnr, namespaces[name], 0, -1, { details = true })
    if #marks > 0 then
      table.insert(out, "")
      table.insert(out, "== ns:" .. name .. " ==")
      for _, m in ipairs(marks) do
        local row, col, d = m[2], m[3], m[4]
        local header = string.format("[%d,%d]", row, col)
        -- Range marks (e.g. ns_cell_anchor's start/end span): show the
        -- span, not a raw byte offset — end_col here is content-derived
        -- (the width of the anchored line), not a volatile counter.
        if d.end_row and (d.end_row ~= row or d.end_col ~= col) then
          header = header .. string.format(" -> [%d,%d]", d.end_row, d.end_col)
        end
        table.insert(out, header)

        if d.hl_group then
          table.insert(out, "  hl: " .. d.hl_group)
        end

        if d.virt_text then
          local text, hls = chunks_text_and_hls(d.virt_text)
          table.insert(out, "  virt_text: " .. text .. hls_suffix(hls))
        end

        if d.virt_lines then
          local pos = d.virt_lines_above and "above" or "below"
          -- Flattened through the existing H.flat_lines for the plain text;
          -- highlight groups are pulled from the same chunk lists alongside
          -- it so a highlight regression (e.g. F2.4's Comment-link bug)
          -- still shows in the diff even though flat_lines itself drops them.
          local flat = H.flat_lines(d.virt_lines)
          for i, line_text in ipairs(flat) do
            local _, hls = chunks_text_and_hls(d.virt_lines[i])
            table.insert(out, string.format(
              "  virt_line[%s]: %s%s", pos, line_text, hls_suffix(hls)))
          end
        end
      end
    end
  end

  -- Image placements (T2 replay layer) live in image.lua's own registry, not
  -- in a namespace this serializer already walks — inline-image backends
  -- (image.nvim/snacks.image, or the T2 test-stub standing in for them) draw
  -- via their own extmarks outside ns_output. Surfacing (key, file) here is
  -- what let a T2 replay case catch the F2.6 registry-migration leak: a
  -- re-key that fails to migrate an old placement key shows up as an extra
  -- or missing line here, not as pixels.
  local image_ok, image_mod = pcall(require, "neo-marimo.image")
  if image_ok and image_mod._placements_for_test then
    local placements = image_mod._placements_for_test(bufnr)
    if placements and next(placements) then
      local keys = {}
      for k in pairs(placements) do table.insert(keys, k) end
      table.sort(keys)
      table.insert(out, "")
      table.insert(out, "== images ==")
      for _, k in ipairs(keys) do
        table.insert(out, string.format("[%s] %s", k, vim.fn.fnamemodify(placements[k].path, ":t")))
      end
    end
  end

  local text = table.concat(out, "\n")
  text = scrub_cell_ids(text, opts.cell_ids)
  for _, rule in ipairs(H.SCRUB_RULES) do
    text = text:gsub(rule.pattern, rule.repl)
  end
  return text
end

return H

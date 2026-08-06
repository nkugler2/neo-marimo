-- T0: tests for the snapshot engine itself (t.snapshot / t.render_state /
-- the scrub rules), as opposed to output_spec.lua / render_spec.lua which
-- exercise it against real renders. Every file this suite creates lives
-- under the "selftest-" prefix and is removed at the end of each case, so
-- these never add or depend on committed goldens under tests/snapshots/.

local t = require("helpers")

local function snapshot_paths(name)
  local dir = t.root .. "/tests/snapshots"
  return dir .. "/" .. name .. ".txt", dir .. "/" .. name .. ".actual.txt"
end

local function cleanup(name)
  local golden, actual = snapshot_paths(name)
  os.remove(golden)
  os.remove(actual)
end

-- vim.fn.setenv is the one portable way to flip an env var mid-process from
-- Lua here (os.getenv has no matching setter); nvim exposes it via libuv.
-- Restores whatever was there before. `value = false` means force-unset
-- (vim.NIL) rather than "leave ambient" — this suite must itself pass when
-- run via `make snapshots`, which sets NEO_MARIMO_UPDATE_SNAPSHOTS=1 for the
-- whole process, so any case asserting "no update env" behavior has to
-- override that ambient value rather than rely on it being absent.
local function with_update_env(value, fn)
  local orig = os.getenv("NEO_MARIMO_UPDATE_SNAPSHOTS")
  vim.fn.setenv("NEO_MARIMO_UPDATE_SNAPSHOTS", value == false and vim.NIL or value)
  local ok, err = pcall(fn)
  vim.fn.setenv("NEO_MARIMO_UPDATE_SNAPSHOTS", orig or vim.NIL)
  if not ok then error(err, 0) end
end

t.case("snapshot: missing golden without the update env fails and names `make snapshots`", function()
  local name = "selftest-missing-no-update"
  cleanup(name)
  with_update_env(false, function()
    local ok, err = pcall(t.snapshot, name, "hello\n")
    t.ok(not ok, "fails without a golden and without the update env")
    t.match(tostring(err), "make snapshots")
  end)
  cleanup(name)
end)

t.case("snapshot: missing golden with the update env writes it and passes", function()
  local name = "selftest-missing-update"
  cleanup(name)
  with_update_env("1", function()
    t.snapshot(name, "hello")
  end)
  local golden_path = snapshot_paths(name)
  local f = assert(io.open(golden_path, "r"), "golden was written")
  t.eq(f:read("*a"), "hello\n", "trailing newline normalized")
  f:close()
  cleanup(name)
end)

t.case("snapshot: matching text passes without touching the golden", function()
  local name = "selftest-match"
  cleanup(name)
  with_update_env("1", function() t.snapshot(name, "same\n") end)
  -- Force the update env unset for this call: a matching golden must still
  -- pass regardless (and this path doesn't touch the update branch at all).
  with_update_env(false, function()
    local ok = pcall(t.snapshot, name, "same\n")
    t.ok(ok, "matching snapshot passes with the update env unset")
  end)
  cleanup(name)
end)

t.case("snapshot: mismatch without the update env fails with a diff and writes .actual.txt", function()
  local name = "selftest-mismatch"
  cleanup(name)
  with_update_env("1", function() t.snapshot(name, "line one\nline two\n") end)

  with_update_env(false, function()
    local ok, err = pcall(t.snapshot, name, "line one\nline THREE\n")
    t.ok(not ok, "mismatch fails")
    local msg = tostring(err)
    t.match(msg, "selftest%-mismatch")
    t.match(msg, "%-line two", "unified diff shows the removed line")
    t.match(msg, "%+line THREE", "unified diff shows the added line")
  end)

  local _, actual_path = snapshot_paths(name)
  local f = assert(io.open(actual_path, "r"), ".actual.txt written on mismatch")
  t.eq(f:read("*a"), "line one\nline THREE\n")
  f:close()
  cleanup(name)
end)

t.case("snapshot: mismatch WITH the update env overwrites the golden and passes", function()
  local name = "selftest-mismatch-update"
  cleanup(name)
  with_update_env("1", function() t.snapshot(name, "old\n") end)
  with_update_env("1", function() t.snapshot(name, "new\n") end)

  local golden_path = snapshot_paths(name)
  local f = assert(io.open(golden_path, "r"))
  t.eq(f:read("*a"), "new\n", "golden overwritten in place")
  f:close()
  cleanup(name)
end)

t.case("snapshot: a passing run cleans up a stale .actual.txt from a prior failure", function()
  local name = "selftest-stale-actual"
  cleanup(name)
  with_update_env("1", function() t.snapshot(name, "good\n") end)
  with_update_env(false, function()
    pcall(t.snapshot, name, "bad\n") -- fails, writes .actual.txt
  end)
  local _, actual_path = snapshot_paths(name)
  t.ok(io.open(actual_path, "r") ~= nil, "sanity: .actual.txt exists after the failure")

  t.snapshot(name, "good\n") -- matches again, regardless of the update env
  t.ok(io.open(actual_path, "r") == nil, ".actual.txt removed once the snapshot matches again")
  cleanup(name)
end)

-- ── t.render_state scrub rules ────────────────────────────────────────────

t.case("render_state: cell ids are scrubbed in first-seen (text position) order", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local hl = require("neo-marimo.highlights")
  vim.api.nvim_buf_set_extmark(bufnr, hl.ns_output, 0, 0, {
    virt_text = { { "cell WXYZ ran, then ABCD ran", "MarimoOutputText" } },
  })
  -- cell_ids order is deliberately the reverse of appearance order in the
  -- text, to prove placeholders are assigned by position in the rendered
  -- output, not by the order the caller happened to list the real ids.
  local text = t.render_state(bufnr, { cell_ids = { "ABCD", "WXYZ" } })
  t.match(text, "cell <cell%-1> ran, then <cell%-2> ran")
  t.no_match(text, "WXYZ")
  t.no_match(text, "ABCD")
end)

t.case("render_state: tmp paths, host:port and durations are scrubbed", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local hl = require("neo-marimo.highlights")
  vim.api.nvim_buf_set_extmark(bufnr, hl.ns_output, 0, 0, {
    virt_text = {
      { "wrote /tmp/neo-marimo-test-7.py in 42ms, served on http://localhost:58231",
        "MarimoOutputText" },
    },
  })
  local text = t.render_state(bufnr)
  t.match(text, "<tmp%-path>")
  t.match(text, "<duration>")
  t.match(text, "localhost:<port>")
  t.no_match(text, "58231")
  t.no_match(text, "42ms")
  t.no_match(text, "neo%-marimo%-test%-7")
end)

t.case("render_state: highlight groups are visible for both virt_text and virt_lines", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local hl = require("neo-marimo.highlights")
  vim.api.nvim_buf_set_extmark(bufnr, hl.ns_output, 0, 0, {
    virt_text = { { "inline", "MarimoOutputText" } },
    virt_lines = { { { "a line", "MarimoOutputError" } } },
  })
  local text = t.render_state(bufnr)
  t.match(text, "virt_text: inline%s+hl=%[MarimoOutputText%]")
  t.match(text, "virt_line%[below%]: a line%s+hl=%[MarimoOutputError%]")
end)

t.case("render_state: groups extmarks by namespace name, not raw numeric ns_id", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local hl = require("neo-marimo.highlights")
  vim.api.nvim_buf_set_extmark(bufnr, hl.ns_output, 0, 0, {
    virt_text = { { "x", "MarimoOutputText" } },
  })
  local text = t.render_state(bufnr)
  t.match(text, "== ns:neo_marimo_output ==")
end)

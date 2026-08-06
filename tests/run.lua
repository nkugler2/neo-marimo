-- neo-marimo test runner. Zero plugin dependencies; runs inside headless
-- nvim so vim.* APIs are real:
--
--   nvim -l tests/run.lua            # run everything
--   nvim -l tests/run.lua html       # only specs/cases whose name matches
--
-- Exit code 0 = all green, 1 = failures (CI-friendly).

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":h:h")

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local t = require("helpers")
t.root = root

-- A positional CLI arg (direct `nvim -l tests/run.lua html` invocation)
-- always wins; otherwise fall back to NEO_MARIMO_TEST_FILTER, which is how
-- `make test`/`make snapshots` pass FILTER through (Makefile's own comment
-- on `export NEO_MARIMO_TEST_FILTER` explains why: putting a value straight
-- into the recipe's process environment, instead of splicing it into recipe
-- text as `$(FILTER)`, is what keeps a case name containing shell
-- metacharacters — e.g. snapshot_spec.lua's backtick-containing case name —
-- from being interpreted by a shell at all).
local filter = _G.arg and _G.arg[1] or nil
if not filter or filter == "" then
  local env_filter = os.getenv("NEO_MARIMO_TEST_FILTER")
  if env_filter and env_filter ~= "" then filter = env_filter end
end

-- Load every spec (they register cases into t.cases as a side effect).
local specs = vim.fn.glob(root .. "/tests/spec/*_spec.lua", false, true)
table.sort(specs)
for _, spec in ipairs(specs) do
  local chunk, err = loadfile(spec)
  if not chunk then
    io.write("LOAD FAIL " .. spec .. ": " .. tostring(err) .. "\n")
    os.exit(1)
  end
  chunk()
end

local pass, fail = 0, 0
local failures = {}

for _, case in ipairs(t.cases) do
  if not filter or case.name:find(filter, 1, true) then
    -- Exposed to helpers.lua's t.snapshot so a failure can name the exact
    -- `make snapshots FILTER=...` invocation that re-selects THIS case (T4)
    -- — the case name (not the snapshot name) is what run.lua's own filter
    -- matches against, and the two aren't always textually related.
    t._current_case = case.name
    local ok, err = xpcall(case.fn, debug.traceback)
    if ok then
      pass = pass + 1
      io.write(".")
    else
      fail = fail + 1
      io.write("F")
      table.insert(failures, { name = case.name, err = err })
    end
  end
end

io.write("\n\n")
for _, f in ipairs(failures) do
  io.write("FAIL: " .. f.name .. "\n" .. tostring(f.err) .. "\n\n")
end

-- End-of-run reports (T7's CORPUS GAPS summary). pcall'd individually so one
-- broken report can't hide another or the pass/fail tally below.
for _, fn in ipairs(t.on_finish or {}) do
  local ok, err = pcall(fn)
  if not ok then io.write("[on_finish] report failed: " .. tostring(err) .. "\n") end
end

io.write(string.format("%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)

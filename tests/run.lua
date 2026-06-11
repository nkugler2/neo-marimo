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

local filter = _G.arg and _G.arg[1] or nil

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
io.write(string.format("%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)

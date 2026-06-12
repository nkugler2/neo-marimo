-- Python bridge round-trip: cells → generate_py → parse_file must preserve
-- code, names, and the `# id:` comments (Phase 7.5.7) exactly. This is the
-- save path's correctness contract — if generate or parse drifts, :w writes
-- a file that reopens differently.
--
-- A round-trip (rather than a golden file) is deliberate: marimo stamps its
-- own version into the generated source, so byte-exact goldens would break
-- on every marimo bump without telling us anything.
--
-- Requires a marimo-equipped python; self-skips otherwise so the suite runs
-- anywhere. `make test` points NEO_MARIMO_TEST_PYTHON at the dev python;
-- CI installs marimo for its runner python.

local t = require("helpers")

local py = vim.fn.expand(vim.env.NEO_MARIMO_TEST_PYTHON or "python3")
local available = vim.fn.executable(py) == 1
  and vim.system({ py, "-c", "import marimo" }):wait().code == 0

if not available then
  io.write("[bridge_spec] skipped: no marimo-equipped python"
    .. " (set NEO_MARIMO_TEST_PYTHON)\n")
  return
end

local parser = require("neo-marimo.parser")

t.case("bridge: generate → parse round-trips code, names, ids", function()
  local filepath = vim.fn.tempname() .. ".py"
  local cells = {
    { name = "_", code = "import marimo as mo", options = {}, id = "AAaa" },
    { name = "compute", code = "x = 1\ny = x + 1", options = {}, id = "BBbb" },
    -- The md string uses marimo's canonical shape (newline after the
    -- opening quotes). marimo's codegen normalises mo.md docstrings to
    -- this form, so a non-canonical input round-trips *changed* on the
    -- first save and is only stable from then on — see the second case.
    { name = "_", code = 'mo.md("""\n# Title\n\nsome prose\n""")', options = {}, id = "CCcc" },
  }

  local src = parser.generate_py(cells, filepath, py)
  t.match(src, "@app%.cell", "generated source has cell decorators")
  t.match(src, "# id: BBbb", "generated source carries the id comments")

  local f = assert(io.open(filepath, "w"))
  f:write(src)
  f:close()

  local data = parser.parse_file(filepath, py)
  os.remove(filepath)

  t.eq(#data.cells, #cells)
  for i, want in ipairs(cells) do
    t.eq(data.cells[i].code, want.code, "cell " .. i .. " code")
    t.eq(data.cells[i].id, want.id, "cell " .. i .. " id")
  end
  t.eq(data.cells[2].name, "compute")
end)

t.case("bridge: second round-trip is stable", function()
  -- generate(parse(generate(x))) == generate(x): saving an unmodified
  -- notebook twice must not keep rewriting the file.
  local filepath = vim.fn.tempname() .. ".py"
  local cells = {
    { name = "_", code = "a = 1", options = {}, id = "QQqq" },
    { name = "_", code = "b = a + 1", options = {}, id = "WWww" },
  }

  local src1 = parser.generate_py(cells, filepath, py)
  local f = assert(io.open(filepath, "w"))
  f:write(src1)
  f:close()

  local data = parser.parse_file(filepath, py)
  local src2 = parser.generate_py(data.cells, filepath, py)
  os.remove(filepath)

  t.eq(src2, src1)
end)

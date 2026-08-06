-- T7: `make corpus-add` (tests/corpus_add.lua). Drives the real script as a
-- subprocess (it os.exit()s at the end, so it can't be require()'d into this
-- process) against a throwaway NEO_MARIMO_CORPUS_DIR — never the repo's real
-- tests/corpus/ — fetching from a `file://` URL so this needs no network
-- access, per the task's explicit "test against a local file:// or dry-run
-- path" instruction (docs/plan-testing.md T7 build step 6).

local t = require("helpers")

local NVIM = vim.v.progpath

-- A throwaway corpus dir seeded with a copy of the REAL manifest.lua (its
-- header comments and existing entries are exactly what the splice logic in
-- corpus_add.lua has to work around without corrupting) but none of the
-- real *.py files — this is the "drop a fresh notebook in" scenario.
local function fresh_corpus_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local src = assert(io.open(t.root .. "/tests/corpus/manifest.lua", "r"))
  local content = src:read("*a")
  src:close()
  local dst = assert(io.open(dir .. "/manifest.lua", "w"))
  dst:write(content)
  dst:close()
  return dir
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- Runs tests/corpus_add.lua with URL/NAME/NEO_MARIMO_CORPUS_DIR set,
-- returns {code, stdout}.
local function run_corpus_add(env)
  local cmd = { NVIM, "-l", t.root .. "/tests/corpus_add.lua" }
  local result = vim.system(cmd, { text = true, env = env }):wait()
  return result.code, (result.stdout or "") .. (result.stderr or "")
end

t.case("corpus-add: fetches a file:// URL into tests/corpus/<name>.py and appends a manifest entry", function()
  local dir = fresh_corpus_dir()
  local source_notebook = vim.fn.tempname() .. ".py"
  local wf = assert(io.open(source_notebook, "w"))
  wf:write("import marimo\n\napp = marimo.App()\n")
  wf:close()

  local code, output = run_corpus_add({
    NEO_MARIMO_CORPUS_DIR = dir,
    URL = "file://" .. source_notebook,
    NAME = "selftest_fetched",
  })
  t.eq(code, 0, "corpus-add exits 0 on a successful fetch: " .. output)

  local fetched = read_file(dir .. "/selftest_fetched.py")
  t.ok(fetched ~= nil, "tests/corpus/selftest_fetched.py was written")
  t.match(fetched, "app = marimo%.App%(%)")

  local manifest_text = read_file(dir .. "/manifest.lua")
  t.match(manifest_text, '%["selftest_fetched"%]%s*=%s*{', "manifest.lua gained an entry for the new notebook")
  t.match(manifest_text, 'source = "file://' .. vim.pesc(source_notebook))
  t.match(manifest_text, 'mode = "exploratory"', "a fresh drop-in defaults to exploratory")

  -- The manifest's own pre-existing entries/comments must survive the
  -- splice untouched — this is a textual insert, not a re-serialize.
  t.match(manifest_text, "intro_tutorial = {", "existing manifest entries are preserved")
  t.match(manifest_text, "^%-%- T7 corpus manifest", "the file's own header comment survives")

  os.remove(source_notebook)
end)

t.case("corpus-add: infers NAME from the URL's own filename when NAME is omitted", function()
  local dir = fresh_corpus_dir()
  local source_dir = vim.fn.tempname()
  vim.fn.mkdir(source_dir, "p")
  local source_notebook = source_dir .. "/inferred_name.py"
  local wf = assert(io.open(source_notebook, "w"))
  wf:write("import marimo\n")
  wf:close()

  local code, output = run_corpus_add({
    NEO_MARIMO_CORPUS_DIR = dir,
    URL = "file://" .. source_notebook,
  })
  t.eq(code, 0, "corpus-add exits 0: " .. output)
  t.ok(read_file(dir .. "/inferred_name.py") ~= nil, "NAME was inferred as 'inferred_name'")
end)

t.case("corpus-add: re-running for an already-listed name leaves the manifest untouched", function()
  local dir = fresh_corpus_dir()
  local source_notebook = vim.fn.tempname() .. ".py"
  local wf = assert(io.open(source_notebook, "w"))
  wf:write("import marimo\n")
  wf:close()

  local env = {
    NEO_MARIMO_CORPUS_DIR = dir,
    URL = "file://" .. source_notebook,
    NAME = "selftest_idempotent",
  }
  local code1 = run_corpus_add(env)
  t.eq(code1, 0)
  local manifest_after_first = read_file(dir .. "/manifest.lua")

  local code2 = run_corpus_add(env)
  t.eq(code2, 0, "re-running for a name already in the manifest still exits 0")
  local manifest_after_second = read_file(dir .. "/manifest.lua")

  t.eq(manifest_after_second, manifest_after_first,
    "a second run must not append a duplicate entry")

  os.remove(source_notebook)
end)

t.case("corpus-add: a curl failure (bad URL) exits non-zero without touching the manifest", function()
  local dir = fresh_corpus_dir()
  local manifest_before = read_file(dir .. "/manifest.lua")

  local code, output = run_corpus_add({
    NEO_MARIMO_CORPUS_DIR = dir,
    URL = "file:///no/such/path/does-not-exist.py",
    NAME = "selftest_failure",
  })
  t.ok(code ~= 0, "corpus-add fails when the fetch fails")
  t.match(output, "curl failed")
  t.eq(read_file(dir .. "/manifest.lua"), manifest_before, "manifest is untouched on a failed fetch")
end)

-- ── NAME validation (a hyphenated/traversal NAME must never reach curl or
-- the manifest splice) ──────────────────────────────────────────────────────

t.case("corpus-add: rejects a hyphenated NAME (invalid as a bare Lua table key) without writing anything", function()
  local dir = fresh_corpus_dir()
  local manifest_before = read_file(dir .. "/manifest.lua")
  local source_notebook = vim.fn.tempname() .. ".py"
  local wf = assert(io.open(source_notebook, "w"))
  wf:write("import marimo\n")
  wf:close()

  local code, output = run_corpus_add({
    NEO_MARIMO_CORPUS_DIR = dir,
    URL = "file://" .. source_notebook,
    NAME = "run-button", -- exactly the shape a URL-basename inference can produce
  })
  t.ok(code ~= 0, "corpus-add rejects a hyphenated NAME: " .. output)
  t.match(output, "not a valid corpus notebook name")
  t.ok(read_file(dir .. "/run-button.py") == nil, "no notebook file was written for a rejected NAME")
  t.eq(read_file(dir .. "/manifest.lua"), manifest_before, "manifest is untouched for a rejected NAME")

  os.remove(source_notebook)
end)

t.case("corpus-add: rejects a NAME containing path traversal without writing anything outside tests/corpus/", function()
  local dir = fresh_corpus_dir()
  local manifest_before = read_file(dir .. "/manifest.lua")
  local source_notebook = vim.fn.tempname() .. ".py"
  local wf = assert(io.open(source_notebook, "w"))
  wf:write("import marimo\n")
  wf:close()

  local escape_target = vim.fn.fnamemodify(dir, ":h") .. "/corpus-add-selftest-escaped.py"
  os.remove(escape_target) -- sanity: doesn't already exist from a previous run

  local code, output = run_corpus_add({
    NEO_MARIMO_CORPUS_DIR = dir,
    URL = "file://" .. source_notebook,
    NAME = "../corpus-add-selftest-escaped",
  })
  t.ok(code ~= 0, "corpus-add rejects a path-traversal NAME: " .. output)
  t.match(output, "not a valid corpus notebook name")
  t.ok(read_file(escape_target) == nil, "nothing was written outside tests/corpus/")
  t.eq(read_file(dir .. "/manifest.lua"), manifest_before, "manifest is untouched for a rejected NAME")

  os.remove(source_notebook)
  os.remove(escape_target)
end)

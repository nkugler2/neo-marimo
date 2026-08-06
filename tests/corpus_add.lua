-- `make corpus-add URL=<raw-github-url> [NAME=<name>]` (T7,
-- docs/plan-testing.md build step 6). Fetches a notebook with curl (already
-- a plugin runtime dependency — server.lua/health.lua both require it on
-- PATH) into tests/corpus/<name>.py and appends a default manifest entry
-- with the source URL filled in, so `make test` picks it up with zero other
-- edits (the same "drop-in" contract tests/corpus.lua's M.entry() gives a
-- notebook that arrives by hand instead).
--
-- Usage:
--   URL=https://raw.githubusercontent.com/... [NAME=my_notebook] \
--     nvim -l tests/corpus_add.lua
--
-- `URL` may be any scheme curl understands, including `file://` — used by
-- this script's own regression case (tests/spec/corpus_add_spec.lua) to
-- exercise the fetch path without hitting the network.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":h")

package.path = table.concat({
  root .. "/?.lua", -- tests/corpus.lua
  package.path,
}, ";")

local corpus = require("corpus")

local URL = os.getenv("URL")
if not URL or URL == "" then
  io.write("corpus-add: URL is required, e.g.\n"
    .. "  make corpus-add URL=https://raw.githubusercontent.com/marimo-team/marimo/main/examples/ui/slider.py\n")
  os.exit(1)
end

local NAME = os.getenv("NAME")
if not NAME or NAME == "" then
  -- Infer from the URL's own filename: ".../examples/ui/slider.py" -> "slider".
  NAME = vim.fn.fnamemodify(URL, ":t:r")
end
if NAME == "" then
  io.write("corpus-add: could not infer a NAME from URL " .. URL .. " — pass NAME= explicitly.\n")
  os.exit(1)
end

-- `NAME` becomes (a) a bare filesystem path segment (corpus.path(NAME)) and
-- (b) a bare Lua table key spliced verbatim into manifest.lua's source text
-- below — so it must be validated BEFORE either of those, not just "cleaned
-- up" after the fact. A hyphen (normal in a URL basename — most marimo
-- example files use underscores, but nothing enforces that) produces
-- `my-name = {...}`, which is not valid Lua and breaks loadfile() for the
-- WHOLE manifest on the next read; `..`/`/` in NAME (e.g. NAME=../evil)
-- reaches corpus.path()'s string-concatenation untouched and can write
-- outside tests/corpus/ entirely. Must start with a letter or underscore
-- (a leading digit is a valid path segment but not a valid bare Lua
-- identifier either) — checked before any curl fetch or manifest edit, so a
-- rejected name touches neither.
if not NAME:match("^[%a_][%w_]*$") then
  io.write(string.format(
    "corpus-add: %q is not a valid corpus notebook name (must match ^[%%a_][%%w_]*$ —"
      .. " start with a letter or underscore, then letters/digits/underscores only;"
      .. " no hyphens, dots, or slashes) — refusing to fetch or write anything.\n"
      .. "  Pass NAME= explicitly with a valid name, e.g. NAME=my_notebook.\n",
    NAME))
  os.exit(1)
end

local dest = corpus.path(NAME)
local existed_already = vim.fn.filereadable(dest) == 1

local result = vim.system({ "curl", "-sS", "-f", "-m", "20", "-o", dest, URL }):wait()
if result.code ~= 0 then
  io.write(string.format(
    "corpus-add: curl failed (exit %d) fetching %s: %s\n",
    result.code, URL, vim.trim(result.stderr or "")))
  os.exit(1)
end
if vim.fn.filereadable(dest) ~= 1 or vim.fn.getfsize(dest) <= 0 then
  io.write("corpus-add: fetch produced an empty/unreadable file at " .. dest .. "\n")
  os.exit(1)
end

io.write(string.format(
  "corpus-add: %s tests/corpus/%s.py from %s\n",
  existed_already and "re-fetched" or "wrote", NAME, URL))

-- ── manifest entry ──────────────────────────────────────────────────────────
--
-- Textual splice, not a round-trip through loadfile+re-serialize: manifest.lua
-- is meant to be hand-edited prose (see its own header comment on `source`/
-- `license`/`mode`/`levels`), and re-serializing the whole table from a
-- loaded Lua value would silently drop every comment in the file. Idempotent
-- (a name already present is left alone) and defaults to "exploratory" with
-- every level — the same default M.entry() would synthesize for a notebook
-- with NO entry at all, just written out explicitly so a human immediately
-- sees a `license` field to fill in before flipping to "strict".
local function already_listed(text, name)
  local pat = vim.pesc(name)
  return text:find("\n%s*" .. pat .. "%s*=%s*{") ~= nil
    or text:find("^%s*" .. pat .. "%s*=%s*{") ~= nil
    or text:find('%[%s*"' .. pat .. '"%s*%]%s*=%s*{') ~= nil -- ["name"] = {...} form
end

local manifest_path = corpus.dir .. "/manifest.lua"
local mf = assert(io.open(manifest_path, "r"), "missing " .. manifest_path)
local manifest_text = mf:read("*a")
mf:close()

if already_listed(manifest_text, NAME) then
  io.write("corpus-add: manifest.lua already has an entry for '" .. NAME .. "' — leaving it alone.\n")
  os.exit(0)
end

-- Quoted `["name"] = {` key form (belt-and-suspenders alongside the NAME
-- validation above): NAME is already known safe at this point, but a quoted
-- string key is valid Lua for any content, so this can never itself be the
-- thing that breaks the manifest even if the validation above is ever
-- loosened or bypassed some other way.
local entry_block = table.concat({
  "",
  '  ["' .. NAME .. '"] = {',
  "    source = " .. vim.inspect(URL) .. ",",
  '    license = "TODO: verify and record this notebook\'s license before flipping to strict",',
  '    mode = "exploratory",',
  "    levels = { 1, 2, 3 },",
  "  },",
}, "\n")

-- Splice right before the final top-level "}" (the manifest's own closing
-- brace, always the last non-blank line — see manifest.lua's own shape).
-- Anchored on end-of-string so this can't misfire on a "}" that closes one
-- of the per-notebook sub-tables instead.
local new_text, n = manifest_text:gsub("\n}%s*$", entry_block .. "\n}\n")
if n ~= 1 then
  io.write("corpus-add: could not find manifest.lua's closing '}' to splice into"
    .. " — add this entry by hand:\n" .. entry_block .. "\n")
  os.exit(1)
end

local wf = assert(io.open(manifest_path, "w"))
wf:write(new_text)
wf:close()

io.write("corpus-add: added a default (exploratory) manifest entry for '" .. NAME .. "'.\n"
  .. "  Fill in its `license` field, and flip `mode` to \"strict\" once its gap report is clean.\n")
os.exit(0)

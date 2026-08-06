-- T7 real-notebook corpus support library (docs/plan-testing.md T7).
--
-- Shared by tests/spec/corpus_spec.lua (levels 1-2, gated/ungated per case)
-- and tests/record_transcripts.lua (level 3's `make transcripts
-- CORPUS=<name>` recording path). Deliberately self-contained (doesn't
-- require tests/helpers.lua for its own root/path plumbing, even though
-- corpus_spec.lua sits right next to helpers-dependent specs) so it works
-- identically from both call sites: run.lua's spec-loading context (where
-- helpers.lua's H.root is pre-set) and record_transcripts.lua's standalone
-- `nvim -l` context (which never touches helpers.lua at all).

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":h:h") -- tests/corpus.lua -> tests -> repo root

local M = {}

-- Overridable so tests/spec/corpus_add_spec.lua can drive tests/
-- corpus_add.lua (a real `nvim -l` subprocess — that script os.exit()s, so
-- it can't be require()'d into the running test process) against a throwaway
-- directory instead of this repo's real tests/corpus/manifest.lua and *.py
-- files. Unset in every normal `make test`/`make transcripts` invocation.
M.dir = os.getenv("NEO_MARIMO_CORPUS_DIR") or (root .. "/tests/corpus")

function M.path(name) return M.dir .. "/" .. name .. ".py" end
function M.parsed_path(name) return M.dir .. "/" .. name .. ".parsed.json" end
function M.gaps_path(name) return M.dir .. "/" .. name .. ".gaps.txt" end

-- ── manifest ──────────────────────────────────────────────────────────────

local DEFAULT_ENTRY = { mode = "exploratory", levels = { 1, 2, 3 } }

local manifest_cache = nil

-- tests/corpus/manifest.lua is a plain `return {...}` table, loaded with
-- loadfile+pcall (not require — it isn't on any require() path and doesn't
-- need to be; dofile-style loading keeps this independent of package.path
-- setup, which record_transcripts.lua and run.lua configure differently).
function M.manifest()
  if manifest_cache then return manifest_cache end
  local chunk, load_err = loadfile(M.dir .. "/manifest.lua")
  if not chunk then
    io.write("[corpus] failed to load manifest.lua: " .. tostring(load_err) .. "\n")
    manifest_cache = {}
    return manifest_cache
  end
  local ok, result = pcall(chunk)
  manifest_cache = (ok and type(result) == "table") and result or {}
  return manifest_cache
end

function M.notebook_names()
  local out = {}
  for _, p in ipairs(vim.fn.glob(M.dir .. "/*.py", false, true)) do
    table.insert(out, vim.fn.fnamemodify(p, ":t:r"))
  end
  table.sort(out)
  return out
end

-- One notice per un-listed/malformed notebook entry per process run (not per
-- case — a notebook gets asked about by up to 3 level cases, and a
-- 3x-repeated notice would just be noise).
local notified = {}

local VALID_MODES = { strict = true, exploratory = true }
local VALID_LEVELS = { [1] = true, [2] = true, [3] = true }

-- Normalize a raw manifest entry (or a synthesized default) into a shape the
-- rest of this module can trust without re-checking: `mode` is one of
-- "strict"/"exploratory", `levels` is always a plain list of 1/2/3.
--
-- A hand-edited manifest.lua entry can carry anything — a typo'd `mode =
-- "Strict"`, a `levels = 5` (not even a table) — and this has to degrade to
-- a safe default with a notice rather than let a bad entry reach
-- `ipairs(entry.levels)` downstream and abort the ENTIRE suite at spec-load
-- time (run.lua's `chunk()` isn't pcall'd, so a Lua error here doesn't stay
-- scoped to one corpus case). Exposed as M._validate_entry_for_test so a
-- regression case can exercise malformed shapes directly, without writing a
-- bad entry into this repo's real, otherwise-valid tests/corpus/manifest.lua.
local function validate_entry(name, raw)
  local entry = vim.tbl_extend("force", DEFAULT_ENTRY, raw)

  if type(entry.mode) ~= "string" or not VALID_MODES[entry.mode] then
    if not notified[name .. ":mode"] then
      notified[name .. ":mode"] = true
      io.write(string.format(
        "[corpus] %s: manifest `mode` %s is not \"strict\" or \"exploratory\" —"
          .. " treating as \"exploratory\".\n", name, vim.inspect(raw.mode)))
    end
    entry.mode = "exploratory"
  end

  if type(entry.levels) ~= "table" then
    if not notified[name .. ":levels"] then
      notified[name .. ":levels"] = true
      io.write(string.format(
        "[corpus] %s: manifest `levels` %s is not a list — using the default"
          .. " {1, 2, 3}.\n", name, vim.inspect(raw.levels)))
    end
    entry.levels = DEFAULT_ENTRY.levels
  else
    local clean, saw_bad = {}, false
    for _, l in ipairs(entry.levels) do
      if VALID_LEVELS[l] then
        table.insert(clean, l)
      else
        saw_bad = true
      end
    end
    if saw_bad and not notified[name .. ":levels"] then
      notified[name .. ":levels"] = true
      io.write(string.format(
        "[corpus] %s: manifest `levels` %s contains invalid entries (valid: 1, 2, 3) —"
          .. " ignoring them.\n", name, vim.inspect(raw.levels)))
    end
    entry.levels = clean
  end

  return entry
end
M._validate_entry_for_test = validate_entry

-- A notebook absent from the manifest still runs — default entry
-- (exploratory, all levels) — the "drop a file in, zero wiring" contract
-- (docs/plan-testing.md T7 build step 1) has to hold before anyone edits
-- manifest.lua.
function M.entry(name)
  local raw = M.manifest()[name]
  if raw then
    return validate_entry(name, raw)
  end
  if not notified[name] then
    notified[name] = true
    io.write(string.format(
      "[corpus] %s: no manifest entry — using generated default (exploratory,"
        .. " all levels). Add one to tests/corpus/manifest.lua to pin mode/"
        .. "source/levels.\n",
      name))
  end
  return vim.tbl_extend("force", { generated = true }, DEFAULT_ENTRY)
end

-- Defensive even though M.entry/validate_entry above already guarantee a
-- clean `entry.levels` table: this is the exact call site the malformed-
-- manifest bug reached (`ipairs(entry.levels or {})` on a non-table `levels`
-- aborts the whole suite, not just one corpus case), and a caller building
-- an ad hoc entry table by hand (as the regression test below does) should
-- never be able to reintroduce that crash just by skipping M.entry.
function M.has_level(entry, n)
  local levels = entry and entry.levels
  if type(levels) ~= "table" then return false end
  for _, l in ipairs(levels) do
    if l == n then return true end
  end
  return false
end

-- ── parsed-cell cache (level 1 writes it, level 2 reads it) ────────────────
--
-- Hand-built with explicitly sorted/fixed key order rather than
-- vim.json.encode(data) directly — same discipline as
-- tests/record_transcripts.lua's action_marker (see its own comment): a
-- committed sidecar that re-orders its own keys on every regeneration would
-- make `git diff` noisy independent of any real content change, and would
-- fail this phase's own "run `make test` twice, git diff clean" acceptance
-- bar. `options` is the one field that can carry >1 key (e.g.
-- {hide_code=true, column=0}), so its keys are sorted too.
local function encode_options(opts)
  if type(opts) ~= "table" then return "{}" end
  local keys = {}
  for k in pairs(opts) do table.insert(keys, k) end
  if #keys == 0 then return "{}" end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, vim.json.encode(k) .. ": " .. vim.json.encode(opts[k]))
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

local function encode_cell(cell)
  return table.concat({
    "    {",
    '      "name": ' .. vim.json.encode(cell.name or "_") .. ",",
    '      "code": ' .. vim.json.encode(cell.code or "") .. ",",
    '      "options": ' .. encode_options(cell.options) .. ",",
    '      "id": ' .. (cell.id and vim.json.encode(cell.id) or "null"),
    "    }",
  }, "\n")
end

local function encode_violations(violations)
  if not violations or #violations == 0 then return "[]" end
  local parts = {}
  for _, v in ipairs(violations) do
    table.insert(parts, string.format('    { "description": %s, "lineno": %s }',
      vim.json.encode(v.description or ""), tostring(v.lineno or vim.NIL)))
  end
  return "[\n" .. table.concat(parts, ",\n") .. "\n  ]"
end

-- Writes tests/corpus/<name>.parsed.json: the level-1 parse result (cell
-- code/name/options/id, plus any parser violations), cached so level 2 can
-- rebuild the same notebook without python. Committed to git for the seeded
-- corpus so level 2 runs on a machine with no marimo at all.
function M.write_parsed(name, data, marimo_version)
  local cell_parts = {}
  for _, cell in ipairs(data.cells or {}) do
    table.insert(cell_parts, encode_cell(cell))
  end
  local text = table.concat({
    "{",
    '  "notebook": ' .. vim.json.encode(name) .. ",",
    '  "marimo_version": ' .. (marimo_version and vim.json.encode(marimo_version) or "null") .. ",",
    '  "cell_count": ' .. #(data.cells or {}) .. ",",
    '  "violations": ' .. encode_violations(data.violations) .. ",",
    '  "cells": [',
    table.concat(cell_parts, ",\n"),
    "  ]",
    "}",
  }, "\n") .. "\n"

  local f = assert(io.open(M.parsed_path(name), "w"))
  f:write(text)
  f:close()
end

function M.load_parsed(name)
  local f = io.open(M.parsed_path(name), "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then return nil end
  return data
end

-- One `python -c "import marimo; print(...)"` subprocess per process run,
-- not one per corpus notebook — every case in corpus_spec.lua that caches a
-- sidecar wants the same string.
local marimo_version_cache = nil
function M.marimo_version(python_path)
  if marimo_version_cache then return marimo_version_cache end
  local result = vim.system(
    { python_path, "-c", "import marimo; print(marimo.__version__)" },
    { text = true }
  ):wait()
  local v = vim.trim(result.stdout or "")
  marimo_version_cache = v ~= "" and v or nil
  return marimo_version_cache
end

-- Parse fresh through the real bridge.py (level 1's own parse call) and cache
-- the result — the one path that keeps the sidecar honest: called with the
-- bridge's own python_path, never hand-constructed. Raises on a bridge
-- failure; callers already run inside a pcall (level 1's round-trip case) or
-- want the raise (a level-2 case self-healing a missing sidecar when python
-- happens to be available in this run).
function M.parse_and_cache(name, python_path)
  local parser = require("neo-marimo.parser")
  local data = parser.parse_file(M.path(name), python_path)
  M.write_parsed(name, data, M.marimo_version(python_path))
  return data
end

function M.codes(data)
  local out = {}
  for _, c in ipairs(data.cells or {}) do table.insert(out, c.code) end
  return out
end

-- ── level 3: corpus transcripts ─────────────────────────────────────────────
--
-- Recorded on demand via `make transcripts CORPUS=<name>` (tests/
-- record_transcripts.lua), written under tests/corpus/transcripts/<version>/
-- — a SEPARATE tree from tests/transcripts/ (the curated T1 scenario
-- corpus), and .gitignore'd wholesale: docs/plan-testing.md T7's "Known
-- risk" paragraph explicitly permits corpus-level transcripts to be
-- `unstable` (re-recorded rather than committed) since third-party notebooks
-- can carry randomness/network fetches the curated scenarios don't. A
-- maintainer who verifies a specific recording IS stable can still `git add
-- -f` it; that's a deliberate per-file opt-in this .gitignore rule doesn't
-- block.
function M.transcript_path(name)
  local dirs = vim.fn.glob(M.dir .. "/transcripts/*", false, true)
  table.sort(dirs, function(a, b) return a > b end)
  if not dirs[1] then return nil end
  local path = dirs[1] .. "/" .. name .. ".jsonl"
  if vim.fn.filereadable(path) == 1 then return path end
  return nil
end

-- ── gap collector (exploratory mode, build step 5) ──────────────────────────

local Gaps = {}
Gaps.__index = Gaps

function M.new_gaps(name)
  return setmetatable({
    name = name,
    parse_warnings = {},
    unknown_widgets = {}, _seen_widgets = {},
    html_punts = {}, _seen_punts = {},
    unknown_ops = {}, _seen_ops = {},
  }, Gaps)
end

local function add_unique(list, seen, value)
  if not seen[value] then
    seen[value] = true
    table.insert(list, value)
  end
end

function Gaps:add_parse_warning(msg) table.insert(self.parse_warnings, msg) end
function Gaps:add_widget(name) add_unique(self.unknown_widgets, self._seen_widgets, name) end
function Gaps:add_html_punt(label) add_unique(self.html_punts, self._seen_punts, label) end
function Gaps:add_unknown_op(op) add_unique(self.unknown_ops, self._seen_ops, op) end

-- Scan a t.render_state() string for the fallback text shapes that mean "no
-- dedicated renderer for this" — narrowed to `virt_line`/`virt_text` rows
-- (the serializer's own format, tests/helpers.lua's H.render_state) rather
-- than the whole snapshot text, so a real notebook's raw source in the
-- "== buffer ==" section can never be misread as a gap marker just because
-- it happens to contain a "[...]" substring.
function Gaps:scan_render_state(text)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^  virt_line%[") or line:match("^  virt_text: ") then
      -- widgets.lua's render_unknown: "  [name] value=...". The trailing
      -- " value=" is what tells this apart from any other bracketed text on
      -- the same line — including this line's OWN trailing "hl=[...]"
      -- suffix, which never has " value=" right after its close-bracket.
      local widget_name = line:match("%[([%w_%-]+)%]%svalue=")
      if widget_name then self:add_widget(widget_name) end

      -- output.lua's output_to_virt_lines fallback for a wholly unrecognized
      -- mimetype: "  [mimetype/subtype]" (output.lua, the final `return {
      -- { { "  [" .. mimetype .. "]" ...` branch).
      local mime = line:match("%[([%w%-%.]+/[%w%-%.%+]+)%]")
      if mime then self:add_html_punt("unrecognized mimetype: " .. mime) end

      -- render_marimo_mime's fallback for an application/vnd.marimo+mime
      -- envelope it can't route anywhere: "[marimo widget — <mime>]".
      local wrapped = line:match("%[marimo widget — ([^%]]+)%]")
      if wrapped then self:add_html_punt("marimo+mime envelope: " .. wrapped) end

      if line:find("install image.nvim or open in browser", 1, true) then
        self:add_html_punt("image (no inline backend, or undecodable payload)")
      end
    end
  end
end

function Gaps:any()
  return #self.parse_warnings > 0 or #self.unknown_widgets > 0
    or #self.html_punts > 0 or #self.unknown_ops > 0
end

-- One line, the shape docs/plan-testing.md T7 specifies verbatim: "CORPUS
-- GAPS: <notebook>: 2 unknown widgets (foo, bar), 1 unknown op (baz)".
-- Returns nil when there's nothing to report (no line emitted for a clean
-- notebook).
function Gaps:summary_line()
  local function plural(n, noun) return n .. " " .. noun .. (n == 1 and "" or "s") end

  local parts = {}
  if #self.unknown_widgets > 0 then
    table.insert(parts, plural(#self.unknown_widgets, "unknown widget")
      .. " (" .. table.concat(self.unknown_widgets, ", ") .. ")")
  end
  if #self.html_punts > 0 then
    table.insert(parts, plural(#self.html_punts, "HTML punt")
      .. " (" .. table.concat(self.html_punts, ", ") .. ")")
  end
  if #self.unknown_ops > 0 then
    table.insert(parts, plural(#self.unknown_ops, "unknown op")
      .. " (" .. table.concat(self.unknown_ops, ", ") .. ")")
  end
  if #self.parse_warnings > 0 then
    table.insert(parts, plural(#self.parse_warnings, "parse warning"))
  end
  if #parts == 0 then return nil end
  return "CORPUS GAPS: " .. self.name .. ": " .. table.concat(parts, ", ")
end

-- Full detail written to tests/corpus/<name>.gaps.txt (gitignored — a local
-- diffing aid, not a golden; the one-line summary above is what's readable
-- straight from `make test` output).
function Gaps:write(path)
  local lines = { "gap report for " .. self.name .. " — regenerated on every `make test` run", "" }
  local function section(title, items)
    if #items == 0 then return end
    table.insert(lines, title)
    for _, item in ipairs(items) do table.insert(lines, "  - " .. item) end
    table.insert(lines, "")
  end
  section("## parse warnings", self.parse_warnings)
  section("## unknown widgets (no registered renderer)", self.unknown_widgets)
  section("## HTML the output renderer punts on", self.html_punts)
  section("## unknown WS ops (level 3 replay)", self.unknown_ops)

  local f = assert(io.open(path, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

return M

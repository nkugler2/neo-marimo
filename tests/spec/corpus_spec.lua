-- T7: real-notebook corpus. Auto-generates up to three cases per notebook
-- under tests/corpus/*.py from tests/corpus/manifest.lua (or a synthesized
-- default entry for a notebook the manifest doesn't mention yet — the
-- drop-in contract). See docs/plan-testing.md T7 for the full design.
--
--   level 1 — parse round-trip through the real bridge.py (gated on
--             NEO_MARIMO_TEST_PYTHON, like bridge_spec.lua). Also (re)writes
--             the committed tests/corpus/<name>.parsed.json sidecar that
--             level 2 reads.
--   level 2 — kernel-free render snapshot from the cached sidecar. Runs on
--             any machine, marimo or not.
--   level 3 — replay a recorded transcript (tests/corpus/transcripts/,
--             `make transcripts CORPUS=<name>`). Self-skips with a notice
--             when nothing has been recorded — the expected steady state for
--             most corpus notebooks (docs/plan-testing.md T7's "Known risk"
--             paragraph: corpus-level transcript determinism isn't
--             required the way it is for T1's curated scenarios).
--
-- "strict" notebooks assert on every level they run; "exploratory"
-- notebooks collect unknowns into a Gaps object instead of failing (see
-- tests/corpus.lua) and the accumulated report prints once, at the very end
-- of the whole suite, via t.after_all — not as a case of its own, which
-- would just sort wherever "corpus_spec.lua" lands alphabetically among the
-- other spec files.

local t = require("helpers")
local corpus = require("corpus")
local ws_handlers = require("neo-marimo.ws_handlers")

local PY = vim.fn.expand(vim.env.NEO_MARIMO_TEST_PYTHON or "python3")
local PY_AVAILABLE = vim.fn.executable(PY) == 1
  and vim.system({ PY, "-c", "import marimo" }):wait().code == 0

if not PY_AVAILABLE then
  io.write("[corpus_spec] level 1 skipped: no marimo-equipped python"
    .. " (set NEO_MARIMO_TEST_PYTHON)\n")
end

-- Same fake "backend" T2's replay_spec.lua uses (see image.lua's
-- _set_test_backend doc comment): real placement bookkeeping, no attempt at
-- an actual terminal escape sequence. Duplicated here rather than shared
-- because replay_spec.lua's copy is a local (file-scoped) helper, and this
-- file's replay only needs it for the rare notebook that both (a) has a
-- level-3 transcript recorded and (b) emits an image.
local function with_image_stub(fn)
  local image = require("neo-marimo.image")
  image._set_test_backend(function() return true end)
  local ok, err = pcall(fn)
  image._set_test_backend(nil)
  if not ok then error(err, 0) end
end

local function cell_ids_of(nb)
  local ids = {}
  for _, c in ipairs(nb.cells) do table.insert(ids, c.id) end
  return ids
end

-- ── regression: a malformed manifest.lua entry must not abort the suite ────
--
-- run.lua's spec-loading `chunk()` call isn't pcall'd, so a bare Lua error
-- raised while THIS FILE is still being loaded (i.e. from the module-level
-- `for` loop below, not from inside a t.case callback) takes down every
-- spec in the run, not just one corpus case. `ipairs(entry.levels or {})`
-- on a non-table `levels` (e.g. a manifest entry with `levels = 5`, a typo
-- for `levels = {5}`) used to do exactly that. Exercised directly against
-- tests/corpus.lua's own functions — a bad entry is never actually written
-- into this repo's real, otherwise-valid tests/corpus/manifest.lua just to
-- prove this.
t.case("corpus: a manifest entry with non-table `levels` degrades to the default instead of crashing", function()
  local entry = corpus._validate_entry_for_test("selftest-bad-levels", { mode = "strict", levels = 5 })
  t.eq(entry.levels, { 1, 2, 3 }, "non-table levels falls back to the full default set")
  t.eq(entry.mode, "strict", "a valid mode alongside a bad `levels` is left alone")
  t.ok(corpus.has_level(entry, 1) and corpus.has_level(entry, 2) and corpus.has_level(entry, 3))
end)

t.case("corpus: a manifest entry with out-of-range `levels` entries drops just the bad ones", function()
  local entry = corpus._validate_entry_for_test("selftest-partial-bad-levels", { levels = { 1, 4, 2, "x" } })
  t.eq(entry.levels, { 1, 2 }, "invalid entries (4, \"x\") are dropped; valid ones (1, 2) survive")
end)

t.case("corpus: a manifest entry with an unrecognized `mode` degrades to exploratory", function()
  local entry = corpus._validate_entry_for_test("selftest-bad-mode", { mode = "Strict" })
  t.eq(entry.mode, "exploratory", "an unrecognized mode (case typo) is not silently treated as strict")
end)

t.case("corpus: M.has_level tolerates a hand-built entry whose `levels` isn't a table at all", function()
  -- Defense in depth for the exact crash site (ipairs on a non-table),
  -- independent of validate_entry ever having run.
  t.ok(not corpus.has_level({ levels = 5 }, 1), "non-table levels: no match, no crash")
  t.ok(not corpus.has_level({}, 1), "missing levels: no match, no crash")
  t.ok(not corpus.has_level(nil, 1), "nil entry: no match, no crash")
end)

-- name -> Gaps, populated as cases are REGISTERED (module load time), read
-- back by the t.after_all report once every case has RUN.
local ALL_GAPS = {}

for _, name in ipairs(corpus.notebook_names()) do
  local entry = corpus.entry(name)
  local gaps = corpus.new_gaps(name)
  ALL_GAPS[name] = gaps

  -- ── level 1: parse round-trip ─────────────────────────────────────────
  if PY_AVAILABLE and corpus.has_level(entry, 1) then
    t.case("corpus: " .. name .. " level 1 parse round-trip (" .. entry.mode .. ")", function()
      local parser = require("neo-marimo.parser")

      local parse_ok, data = pcall(parser.parse_file, corpus.path(name), PY)
      if not parse_ok then
        local msg = "parse failed: " .. tostring(data)
        gaps:add_parse_warning(msg)
        t.ok(entry.mode ~= "strict", name .. ": " .. msg)
        return
      end

      for _, v in ipairs(data.violations or {}) do
        gaps:add_parse_warning(string.format("line %s: %s", tostring(v.lineno), v.description))
      end

      -- Regenerate -> reparse; cell count/codes must be stable (this is the
      -- save path's own contract, bridge_spec.lua's "generate -> parse
      -- round-trips" case — here run against real third-party notebook
      -- shapes instead of hand-built fixtures).
      local gen_ok, src = pcall(parser.generate_py, data.cells, corpus.path(name), PY)
      if not gen_ok then
        local msg = "generate failed: " .. tostring(src)
        gaps:add_parse_warning(msg)
        t.ok(entry.mode ~= "strict", name .. ": " .. msg)
      else
        local tmp = vim.fn.tempname() .. ".py"
        local wf = assert(io.open(tmp, "w"))
        wf:write(src)
        wf:close()
        local reparse_ok, data2 = pcall(parser.parse_file, tmp, PY)
        os.remove(tmp)

        if not reparse_ok then
          local msg = "reparse of regenerated source failed: " .. tostring(data2)
          gaps:add_parse_warning(msg)
          t.ok(entry.mode ~= "strict", name .. ": " .. msg)
        elseif entry.mode == "strict" then
          t.eq(#data2.cells, #data.cells, name .. ": cell count drifted across a round-trip")
          for i, cell in ipairs(data.cells) do
            t.eq(data2.cells[i].code, cell.code, name .. ": cell " .. i .. " code drifted across a round-trip")
          end
        else
          if #data2.cells ~= #data.cells then
            gaps:add_parse_warning(string.format(
              "cell count drifted across a round-trip: %d -> %d", #data.cells, #data2.cells))
          else
            for i, cell in ipairs(data.cells) do
              if data2.cells[i].code ~= cell.code then
                gaps:add_parse_warning("cell " .. i .. " code drifted across a round-trip")
              end
            end
          end
        end
      end

      -- (Re)cache the sidecar from the ORIGINAL parse (not the regenerated
      -- one) so level 2 always builds the notebook from exactly what the
      -- committed .py contains, independent of whether the round-trip above
      -- was clean. Committed to git for the seeded corpus; refreshed here so
      -- a deleted sidecar self-heals the next time a marimo-equipped python
      -- runs `make test`.
      corpus.write_parsed(name, data, corpus.marimo_version(PY))
    end)
  end

  -- ── level 2: kernel-free render snapshot ────────────────────────────────
  if corpus.has_level(entry, 2) then
    t.case("corpus: " .. name .. " level 2 kernel-free render snapshot (" .. entry.mode .. ")", function()
      local data = corpus.load_parsed(name)
      local regen_err = nil
      if not data and PY_AVAILABLE then
        -- Self-heal even when level 1 above didn't run first (e.g. `make
        -- test FILTER="level 2"`) — level 2 shouldn't have to assume
        -- ordering against a sibling case in the same file.
        local ok, result = pcall(corpus.parse_and_cache, name, PY)
        if ok then data = result else regen_err = result end
      end
      if not data then
        local msg = "missing " .. corpus.parsed_path(name) .. "."
        if PY_AVAILABLE then
          msg = msg .. " Tried to regenerate it but bridge.py failed: " .. tostring(regen_err)
        else
          msg = msg .. " No marimo-equipped python available to regenerate it —"
            .. " set NEO_MARIMO_TEST_PYTHON and run `make test` once to create it."
        end
        -- A freshly `corpus-add`'d notebook on a marimo-less machine hits
        -- exactly this path (no committed sidecar yet, no python to make
        -- one) — that's a real, expected exploratory state, not a suite
        -- failure; route it into the gap report like the level-1
        -- parse-failure branches above. Strict notebooks (which SHOULD
        -- always have a committed sidecar) still fail loudly.
        gaps:add_parse_warning(msg)
        t.ok(entry.mode ~= "strict", "corpus: " .. name .. ": " .. msg)
        return
      end

      local nb, bufnr = t.make_notebook(corpus.codes(data))
      local state = t.render_state(bufnr, { cell_ids = cell_ids_of(nb) })
      gaps:scan_render_state(state)

      if entry.mode == "strict" then
        t.snapshot("corpus-" .. name, state)
        -- gaps may already carry level-1 findings (parse warnings, a failed
        -- round-trip) — this is the SAME Gaps object across all three level
        -- cases for a notebook, by design, so a strict failure here can
        -- point at something level 1 already found.
        t.ok(not gaps:any(), name .. ": strict notebook produced gap(s) — "
          .. tostring(gaps:summary_line()))
      else
        -- Exploratory: still snapshot (a regression baseline is useful even
        -- for a notebook we don't fully support yet), but a mismatch is
        -- recorded as a gap, not a suite failure — flipping this notebook to
        -- "strict" once its report is clean is what turns the snapshot back
        -- into an enforced regression.
        local ok, err = pcall(t.snapshot, "corpus-" .. name, state)
        if not ok then
          gaps:add_parse_warning("level 2 render changed vs. its snapshot (exploratory, not failing): "
            .. tostring(err):match("^[^\n]*"))
        end
      end
    end)
  end

  -- ── level 3: recorded transcript + replay ───────────────────────────────
  if corpus.has_level(entry, 3) then
    t.case("corpus: " .. name .. " level 3 recorded replay (" .. entry.mode .. ")", function()
      local transcript_path = corpus.transcript_path(name)
      if not transcript_path then
        io.write("\n  [corpus] " .. name .. ": level 3 skipped — no recorded transcript"
          .. " (run `make transcripts CORPUS=" .. name .. "` to record one; see"
          .. " docs/plan-testing.md T7)\n")
        return
      end

      local data = corpus.load_parsed(name)
      if not data and PY_AVAILABLE then
        local ok, result = pcall(corpus.parse_and_cache, name, PY)
        if ok then data = result end
      end
      if not data then
        -- Same reasoning as level 2's missing-sidecar branch above: real for
        -- an exploratory notebook on a marimo-less machine, not a suite
        -- failure.
        local msg = name .. ": have a level-3 transcript but no parsed sidecar to build the notebook from"
        gaps:add_parse_warning(msg)
        t.ok(entry.mode ~= "strict", msg)
        return
      end

      with_image_stub(function()
        local nb, bufnr = t.make_notebook(corpus.codes(data))

        local unknown_ops = {}
        local errors_before = vim.deepcopy(ws_handlers._handler_errors)
        t.replay(name, nb, bufnr, {
          path = transcript_path,
          on_dispatch = function(op, _payload, ok)
            if not ok then
              local threw = (ws_handlers._handler_errors[op] or 0) > (errors_before[op] or 0)
              if not threw then table.insert(unknown_ops, op) end
            end
          end,
        })
        for _, op in ipairs(unknown_ops) do gaps:add_unknown_op(op) end

        local state = t.render_state(bufnr, { cell_ids = cell_ids_of(nb) })
        gaps:scan_render_state(state)

        if entry.mode == "strict" then
          t.eq(unknown_ops, {}, name .. ": unhandled WS op(s) in the recorded transcript")
          t.snapshot("corpus-" .. name .. "-replay", state)
        else
          pcall(t.snapshot, "corpus-" .. name .. "-replay", state) -- best-effort; gaps already recorded above
        end
      end)
    end)
  end
end

-- ── end-of-run gap report ────────────────────────────────────────────────

t.after_all(function()
  local lines = {}
  for _, name in ipairs(corpus.notebook_names()) do
    local gaps = ALL_GAPS[name]
    if gaps then
      gaps:write(corpus.gaps_path(name))
      local summary = gaps:summary_line()
      if summary then table.insert(lines, summary) end
    end
  end
  if #lines > 0 then
    io.write("\n" .. table.concat(lines, "\n") .. "\n")
  end
end)

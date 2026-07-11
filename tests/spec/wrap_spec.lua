-- Unit tests for output.lua's virt_line wrap pass (Phase 11.8). virt_lines
-- can't scroll horizontally, so over-wide lines are hard-wrapped at the
-- window text width before the extmark is set.

local t = require("helpers")
local output = require("neo-marimo.output")

local wrap = output._wrap_virt_line

local function widths(lines)
  local out = {}
  for _, l in ipairs(t.flat_lines(lines)) do
    table.insert(out, vim.fn.strdisplaywidth(l))
  end
  return out
end

t.case("wrap: line within width passes through untouched", function()
  local line = { { "  short line", "MarimoOutputText" } }
  local got = wrap(line, 40)
  t.eq(got, { line })
end)

t.case("wrap: long prose wraps at word boundaries with indent", function()
  local line = { { "  the quick brown fox jumps over the lazy dog again", "MarimoOutputText" } }
  local got = wrap(line, 30)
  t.ok(#got > 1, "wrapped into multiple lines")
  for _, w in ipairs(widths(got)) do
    t.ok(w <= 30, "every line fits (" .. w .. " > 30)")
  end
  local flat = t.flat_lines(got)
  -- No mid-word split: every line ends/starts on whole words.
  for _, l in ipairs(flat) do
    t.no_match(l, "qui$")
    t.no_match(l, "jum$")
  end
  t.match(flat[2], "^  %S", "continuation gets the standard two-space indent")
  -- Nothing lost in the wrap.
  local rejoined = table.concat(flat, " "):gsub("%s+", " ")
  t.match(rejoined, "lazy dog again$")
end)

t.case("wrap: highlights survive a chunk split", function()
  local line = {
    { "  label: ", "MarimoWidgetLabel" },
    { string.rep("x", 60), "MarimoWidgetValue" },
  }
  local got = wrap(line, 30)
  t.ok(#got >= 2, "split happened")
  -- The overflowing chunk keeps its highlight group on every fragment.
  local seen = 0
  for _, l in ipairs(got) do
    for _, ch in ipairs(l) do
      if ch[2] == "MarimoWidgetValue" then seen = seen + 1 end
    end
  end
  t.ok(seen >= 2, "value highlight present on both sides of the split")
end)

t.case("wrap: multibyte content splits codepoint-safe", function()
  -- Box-drawing chars: 3 bytes / 1 display cell each. A byte-based split
  -- would slice one in half and produce garbage.
  local line = { { "  │" .. string.rep("─", 60) .. "│", "MarimoWidgetBoxBorder" } }
  local got = wrap(line, 25)
  for _, l in ipairs(t.flat_lines(got)) do
    t.ok(vim.fn.strdisplaywidth(l) <= 25, "fits in width")
    -- Re-encoding sanity: every fragment is valid UTF-8 (nvim_strwidth
    -- errors on invalid sequences).
    local ok = pcall(vim.api.nvim_strwidth, l)
    t.ok(ok, "valid utf-8 after split")
  end
end)

t.case("wrap: pathological narrow width still terminates", function()
  local line = { { string.rep("a", 100), "MarimoOutputText" } }
  local got = wrap(line, 1)  -- clamped to 12 internally
  t.ok(#got >= 2, "wrapped")
  for _, w in ipairs(widths(got)) do
    t.ok(w <= 12, "respects the clamped minimum width")
  end
end)

-- F6.3 / documents-not-fixes (see docs/plan-refinement.md's Deferred section,
-- "Numpy/DataFrame width"): numpy's repr embeds its own hard line breaks at
-- its default linewidth=75 BEFORE the payload ever reaches this module —
-- render_text_plain splits the raw string into one virt_line per embedded
-- "\n", and wrap_virt_line only ever operates on one already-split line at a
-- time (it has no visibility into a neighbouring line to rejoin with). So two
-- lines the kernel broke apart stay apart forever, even in a window wide
-- enough to hold both concatenated on one row — this is NOT a wrap_virt_line
-- bug, it's the documented, working-as-designed limit of a per-line wrapper.
-- This spec pins the current behavior so a future change doesn't
-- accidentally "fix" it into unpredictable cross-line rejoining; an actual
-- fix (if ever done) would be upstream — pushing a window-width
-- np.set_printoptions(linewidth=...) hint into the kernel — and is out of
-- scope here.
t.case("wrap: kernel-pre-split lines (numpy linewidth-style) never rejoin, even when width allows it", function()
  -- Two lines shaped like numpy's default repr wrap (~75 display cells each,
  -- already broken apart by the kernel before this module ever sees them).
  local line1 = { { "  " .. string.rep("1", 73), "MarimoOutputText" } }
  local line2 = { { "  " .. string.rep("2", 73), "MarimoOutputText" } }

  -- Wide enough to hold BOTH source lines concatenated on one row (75 + 75 =
  -- 150 < 200) — if wrap_virt_line could see and rejoin pre-split lines,
  -- this width is exactly what would let it collapse them into one.
  local wrapped1 = wrap(line1, 200)
  local wrapped2 = wrap(line2, 200)

  t.eq(#wrapped1, 1, "line 1 passes through unchanged (fits under width on its own)")
  t.eq(#wrapped2, 1, "line 2 passes through unchanged (fits under width on its own)")
  -- output.render's loop calls wrap_virt_line once per already-split
  -- virt_line, exactly mirrored here by two independent calls — there is no
  -- code path that looks across them, so the result can only ever be 2
  -- rendered lines, never 1.
  t.eq(#wrapped1 + #wrapped2, 2,
    "two kernel-embedded lines render as two lines, never rejoined into one")
end)

-- Regression: a huge single chunk (a base64 image blob that missed the image
-- path) must NOT drive the O(n²) wrap into a multi-minute freeze. It's
-- truncated up front so the wrap stays fast and bounded.
t.case("wrap: a megabyte-long chunk is truncated, not wrapped forever", function()
  local line = { { string.rep("A", 1500000), "MarimoOutputText" } }  -- ~1.5 MB
  local t0 = vim.uv.hrtime()
  local got = wrap(line, 80)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  t.ok(ms < 1000, "wrap completed quickly (" .. math.floor(ms) .. " ms), not frozen")
  -- The truncation marker survives into the wrapped output.
  local flat = t.flat_lines(got)
  t.match(table.concat(flat, "\n"), "…", "truncation ellipsis present")
  -- And the total kept content is bounded well under the original.
  local total = 0
  for _, l in ipairs(flat) do total = total + #l end
  t.ok(total < 64 * 1024, "kept content bounded (" .. total .. " bytes)")
end)

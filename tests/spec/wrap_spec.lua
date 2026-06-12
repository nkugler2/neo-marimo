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

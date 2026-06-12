-- Display-width correctness in the dataframe renderers (Phase 11.4).
-- Widths are display cells, not bytes, so non-ASCII headers/values keep
-- the table grid aligned.

local t = require("helpers")
local dataframe = require("neo-marimo.dataframe")

t.case("dataframe: inline render aligns non-ASCII content", function()
  local df = {
    cols = { "名前", "value" },
    rows = {
      { ["名前"] = "東京", value = 1 },
      { ["名前"] = "ok", value = 22222 },
    },
  }
  local lines = t.flat_lines(dataframe.render_inline(df))
  t.ok(#lines >= 4, "header + separator + 2 rows")
  local want = vim.fn.strdisplaywidth(lines[1])
  for i, l in ipairs(lines) do
    t.eq(vim.fn.strdisplaywidth(l), want,
      "line " .. i .. " display width matches header")
  end
end)

t.case("dataframe: inline render truncates wide values codepoint-safe", function()
  local df = {
    cols = { "c" },
    rows = { { c = string.rep("漢", 30) } },  -- 60 cells, over the 20-cell cap
  }
  local lines = t.flat_lines(dataframe.render_inline(df))
  for _, l in ipairs(lines) do
    local ok = pcall(vim.api.nvim_strwidth, l)
    t.ok(ok, "valid utf-8 after truncation")
    t.eq(vim.fn.strdisplaywidth(l), vim.fn.strdisplaywidth(lines[1]),
      "grid stays aligned")
  end
end)

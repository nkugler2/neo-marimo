-- sync.lua's own-write dedup: matches_recent_write hashes a comment-free
-- version of the file so marimo's --watch rewrite (which drops our `# id:`
-- comments) still hashes equal to what we wrote. F1.4: that stripping must
-- only fire for an id-shaped comment immediately preceding `@app.cell` —
-- the exact shape bridge.py's inject_cell_ids writes — otherwise a user's
-- own comment that merely matches the `# id: XXXX` shape gets stripped too
-- and can hash-collide with an unrelated recorded write, making a genuine
-- external edit look like our own echo and get silently swallowed.

local t = require("helpers")
local sync = require("neo-marimo.sync")

t.case("sync: id-shaped comment not immediately before @app.cell is not stripped", function()
  local written = table.concat({
    "@app.cell",
    "def _():",
    "    x = 1",
    "    return x",
    "",
    "",
    "@app.cell",
    "def _():",
    "    y = 2",
    "    return y",
  }, "\n")

  -- Seed the recent-writes ring as if `written` (with no id comments) was
  -- our last save.
  local nb = { _recent_write_hashes = { vim.fn.sha256(written) } }

  -- A user comment that happens to match our id-comment shape but sits
  -- mid-body, not directly above `@app.cell`. Under the old "strip any
  -- matching line" rule this collapses onto the same hash as `written`
  -- and the edit would be mistaken for our own echo.
  local edited = table.concat({
    "@app.cell",
    "def _():",
    "    # id: user123",
    "    x = 1",
    "    return x",
    "",
    "",
    "@app.cell",
    "def _():",
    "    y = 2",
    "    return y",
  }, "\n")

  t.eq(sync.matches_recent_write(nb, edited), false,
    "mid-body comment must not be stripped, so the external edit is detected")
end)

t.case("sync: id comment immediately before @app.cell still dedups against the recorded write", function()
  local written = table.concat({
    "@app.cell",
    "def _():",
    "    x = 1",
    "    return x",
  }, "\n")

  -- Simulates marimo's --watch echoing our write back with the id comment
  -- it round-tripped from the .py source (the case this function exists
  -- for in the first place).
  local echoed = table.concat({
    "# id: AAaa",
    "@app.cell",
    "def _():",
    "    x = 1",
    "    return x",
  }, "\n")

  local nb = { _recent_write_hashes = { vim.fn.sha256(written) } }
  t.eq(sync.matches_recent_write(nb, echoed), true,
    "a real id comment directly above @app.cell is still stripped for the own-write hash")
end)

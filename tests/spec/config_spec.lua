-- config.get() is the single authoritative accessor call sites should use
-- instead of re-encoding config.defaults literals (plan-refinement F5.3).
-- These cases save/restore M.options around each test since config is a
-- shared module and other specs may run in the same process.

local t = require("helpers")
local config = require("neo-marimo.config")

local function with_options(options, fn)
  local saved = config.options
  config.options = options
  local ok, err = pcall(fn)
  config.options = saved
  t.ok(ok, err)
end

t.case("config.get: falls back to default when options lack the key entirely", function()
  with_options({}, function()
    t.eq(config.get("python_path"), config.defaults.python_path)
    t.eq(config.get("server.port"), config.defaults.server.port)
  end)
end)

-- F5.4: browser_handoff_delay_ms replaced a hardcoded 1200 literal in
-- server.lua's hand_off_to_browser — must resolve through config.get.
t.case("config.get: browser_handoff_delay_ms has the documented default", function()
  with_options({}, function()
    t.eq(config.get("server.browser_handoff_delay_ms"), 1200)
    t.eq(config.get("server.browser_handoff_delay_ms"), config.defaults.server.browser_handoff_delay_ms)
  end)
end)

t.case("config.get: returns the user value after setup() with a partial override", function()
  config.setup({ server = { port = 9999 } })
  t.eq(config.get("server.port"), 9999)
  -- Untouched sibling keys still resolve — tbl_deep_extend("force", ...)
  -- merges the partial override onto the full defaults table.
  t.eq(config.get("server.host"), config.defaults.server.host)
  t.eq(config.get("python_path"), config.defaults.python_path)
end)

-- The regression class config.get exists to prevent: a naive
-- `options[k] or defaults[k]` walk would let an explicit user `false`
-- fall through to a `true` default (e.g. server.share_with_browser).
-- get() must distinguish "set to false" from "not set" (nil).
t.case("config.get: an explicit false in options is not overridden by a true default", function()
  with_options({ server = { share_with_browser = false } }, function()
    t.eq(config.defaults.server.share_with_browser, true)
    t.eq(config.get("server.share_with_browser"), false)
  end)
end)

t.case("config.get: nested path resolves when the intermediate table is missing from options", function()
  with_options({}, function()
    -- M.options is {} pre-setup (or reset here to simulate it) — "server"
    -- itself is missing, not just "server.port" — get() must not error
    -- walking into a nil table and must still find the default.
    t.eq(config.get("server.port"), config.defaults.server.port)
    t.eq(config.get("server.host"), config.defaults.server.host)
  end)
end)

t.case("config.get: unknown path returns nil rather than erroring", function()
  with_options({}, function()
    t.eq(config.get("server.does_not_exist"), nil)
    t.eq(config.get("does.not.exist.at.all"), nil)
  end)
end)

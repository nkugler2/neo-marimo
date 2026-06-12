-- WS dispatch error containment: a handler that throws on an unexpected
-- payload must produce exactly one warning and never an error loop —
-- marimo streams dozens of messages per run, so an uncontained error
-- would repeat for every subsequent message.

local t = require("helpers")
local ws = require("neo-marimo.ws_handlers")

t.case("ws: throwing handler is contained and warned once", function()
  local notify_count = 0
  local orig_notify = vim.notify
  vim.notify = function() notify_count = notify_count + 1 end

  ws.register("test-explode", function() error("boom") end)
  local ok1 = ws.dispatch("test-explode", {}, {})
  local ok2 = ws.dispatch("test-explode", {}, {})
  local ok3 = ws.dispatch("test-explode", {}, {})

  vim.notify = orig_notify
  ws.handlers["test-explode"] = nil
  ws._handler_errors["test-explode"] = nil

  t.eq(ok1, false)
  t.eq(ok2, false)
  t.eq(ok3, false)
  t.eq(notify_count, 1, "exactly one warning for repeated handler failures")
end)

t.case("ws: healthy handlers still dispatch normally", function()
  local seen = nil
  ws.register("test-ok", function(payload) seen = payload.value end)
  local ok = ws.dispatch("test-ok", { value = 42 }, {})
  ws.handlers["test-ok"] = nil

  t.eq(ok, true)
  t.eq(seen, 42)
end)

t.case("ws: unknown op returns false without error", function()
  t.eq(ws.dispatch("no-such-op", {}, {}), false)
end)

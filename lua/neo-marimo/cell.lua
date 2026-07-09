local utils = require("neo-marimo.utils")
local log = require("neo-marimo.log")

local M = {}

-- Cell-type detector chain. Each entry is { predicate(code) -> bool, type }.
-- Walked in order; the first matching entry wins. `python` is the implicit
-- fallback if nothing matches.
--
-- Local, not `M.detectors` (plan-refinement F4.4): the registry storage
-- itself isn't part of the frozen public surface — register_detector is the
-- only supported write path (mirrors widgets.lua's local RENDERERS, which
-- predates this cleanup; output.lua and ws_handlers.lua were the outliers).
-- Other modules extend the chain via M.register_detector at setup time
-- (e.g. Phase 4 registers the `mo`-widget detector).
local detectors = {}

-- Register a detector, or deregister every detector for `type_name` when
-- `predicate` is nil. `priority` (optional, default 50) controls position;
-- lower priorities run first. We re-sort the chain after every register.
-- The nil-predicate deregister path (plan-refinement F4.4) mirrors
-- output.register_renderer / ws_handlers.register / widgets.register_renderer
-- (register_X(key, nil) removes) — needed because F4.1's tests register a
-- throwing detector and must clean it up so later specs see the stock chain,
-- and the detector list is no longer reachable to splice directly now that
-- it's local.
function M.register_detector(type_name, predicate, priority)
  if predicate == nil then
    for i = #detectors, 1, -1 do
      if detectors[i].type == type_name then table.remove(detectors, i) end
    end
    return
  end
  table.insert(detectors, {
    predicate = predicate,
    type = type_name,
    priority = priority or 50,
  })
  table.sort(detectors, function(a, b) return a.priority < b.priority end)
end

-- Per-type-name error counts for the containment below (plan-refinement
-- F4.1), mirroring ws_handlers' once-per-op pattern. Exposed for tests.
M._detector_errors = {}

-- Detect the cell type by walking the chain.
-- Returns the matched type, or "python" if none matched.
--
-- Each predicate is pcall'd (plan-refinement F4.1): before this, a throwing
-- detector — built-in or third-party via M.register_detector — raised
-- straight out of M.detect_type, which cell.new calls unconditionally for
-- every parsed cell, so one bad predicate broke the whole parse and the
-- notebook never attached. A throwing detector is now skipped (warned once
-- per type name) and detection falls through to the remaining detectors /
-- the "python" default, same as if that detector had simply returned false.
function M.detect_type(code)
  if not code or code == "" then
    return "python"
  end
  for _, d in ipairs(detectors) do
    local ok, matched = pcall(d.predicate, code)
    if ok then
      if matched then return d.type end
    else
      M._detector_errors[d.type] = (M._detector_errors[d.type] or 0) + 1
      if M._detector_errors[d.type] == 1 then
        utils.warn(
          "Cell detector for '" .. tostring(d.type) .. "' failed: " .. tostring(matched)
            .. "\nFurther failures for this detector will be suppressed."
        )
      end
      log.write("cell:detector_error", { type = d.type, err = tostring(matched) })
    end
  end
  return "python"
end

-- ── Built-in detectors ──────────────────────────────────────────────────────

-- markdown: `mo.md(...)` or `return mo.md(...)` at top of cell
M.register_detector("markdown", function(code)
  return code:match("^%s*mo%.md%s*%(") ~= nil
      or code:match("^%s*return%s*mo%.md%s*%(") ~= nil
end, 10)

-- sql: `mo.sql(...)` anywhere in the cell
M.register_detector("sql", function(code)
  return code:match("mo%.sql%s*%(") ~= nil
end, 20)

-- marimo widget: cell body is a single `mo.ui.*`, `mo.hstack`, `mo.vstack`,
-- `mo.tabs`, etc. call with no surrounding logic. We anchor on `^mo%.` and
-- `%)$` after trimming — assignments, def, and import statements won't start
-- with `mo.`, so they fall through to the python default.
M.register_detector("marimo", function(code)
  local trimmed = code:match("^%s*(.-)%s*$") or ""
  if not trimmed:match("^mo%.") then return false end
  if not trimmed:match("%)$") then return false end
  return true
end, 30)

-- Create a new cell table from parsed data.
-- `index` is the 1-based position in the notebook.
function M.new(data, index)
  local cell = {
    id = data.id or require("neo-marimo.utils").generate_cell_id(),
    name = data.name or "_",
    code = data.code or "",
    options = data.options or {},
    start_row = 0,  -- 0-indexed buffer row (inclusive), set by buffer.lua
    end_row = 0,    -- 0-indexed buffer row (inclusive), set by buffer.lua
    output = nil,
    status = "idle",
    index = index,
    -- extmark IDs, populated during rendering
    top_mark_id = nil,
    bot_mark_id = nil,
    -- Range extmark in ns_cell_anchor spanning [start_row, end_row]; set by
    -- buffer.place_cell_anchors, not here (a fresh cell has no buffer rows
    -- yet at construction time). See buffer.lua for the gravity rationale.
    anchor_mark_id = nil,
  }
  cell.type = M.detect_type(cell.code)
  return cell
end

-- Count lines in a cell's code string.
function M.line_count(cell)
  if cell.code == "" then
    return 1
  end
  local count = 1
  for _ in cell.code:gmatch("\n") do
    count = count + 1
  end
  return count
end

-- Returns true if the cell has the `disabled` config option set.
function M.is_disabled(cell)
  return cell.options and cell.options.disabled == true
end

return M

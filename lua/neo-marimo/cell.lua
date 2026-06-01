local M = {}

-- Cell-type detector chain. Each entry is { predicate(code) -> bool, type }.
-- Walked in order; the first matching entry wins. `python` is the implicit
-- fallback if nothing matches.
--
-- Other modules can extend the chain via M.register_detector at setup time
-- (e.g. Phase 4 registers the `mo`-widget detector).
M.detectors = {}

-- Register a detector. `priority` (optional, default 50) controls position;
-- lower priorities run first. We re-sort the chain after every register.
function M.register_detector(predicate, type_name, priority)
  table.insert(M.detectors, {
    predicate = predicate,
    type = type_name,
    priority = priority or 50,
  })
  table.sort(M.detectors, function(a, b) return a.priority < b.priority end)
end

-- Detect the cell type by walking the chain.
-- Returns the matched type, or "python" if none matched.
function M.detect_type(code)
  if not code or code == "" then
    return "python"
  end
  for _, d in ipairs(M.detectors) do
    if d.predicate(code) then
      return d.type
    end
  end
  return "python"
end

-- ── Built-in detectors ──────────────────────────────────────────────────────

-- markdown: `mo.md(...)` or `return mo.md(...)` at top of cell
M.register_detector(function(code)
  return code:match("^%s*mo%.md%s*%(") ~= nil
      or code:match("^%s*return%s*mo%.md%s*%(") ~= nil
end, "markdown", 10)

-- sql: `mo.sql(...)` anywhere in the cell
M.register_detector(function(code)
  return code:match("mo%.sql%s*%(") ~= nil
end, "sql", 20)

-- marimo widget: cell body is a single `mo.ui.*`, `mo.hstack`, `mo.vstack`,
-- `mo.tabs`, etc. call with no surrounding logic. We anchor on `^mo%.` and
-- `%)$` after trimming — assignments, def, and import statements won't start
-- with `mo.`, so they fall through to the python default.
M.register_detector(function(code)
  local trimmed = code:match("^%s*(.-)%s*$") or ""
  if not trimmed:match("^mo%.") then return false end
  if not trimmed:match("%)$") then return false end
  return true
end, "marimo", 30)

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

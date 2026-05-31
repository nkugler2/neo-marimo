local M = {}

-- Detect the cell type from its code content.
-- Returns "markdown", "sql", or "python".
function M.detect_type(code)
  if not code or code == "" then
    return "python"
  end
  -- Match mo.md( possibly with keyword arg: mo.md(r"""...""") or mo.md(text=...)
  if code:match("^%s*mo%.md%s*%(") or code:match("^%s*return%s*mo%.md%s*%(") then
    return "markdown"
  end
  -- Match mo.sql( anywhere in the code
  if code:match("mo%.sql%s*%(") then
    return "sql"
  end
  return "python"
end

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

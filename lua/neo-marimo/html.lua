-- Phase 9.1 — HTML element-tree parser.
--
-- Marimo serializes cell output as well-formed HTML built from custom
-- elements (<marimo-slider>, <marimo-tabs>, …), flex-layout <div>s, and
-- markdown wrapper <span>s. The regex-chain parsing this module replaces
-- could only see one level of that structure at a time, which is how nested
-- payloads (tabs containing tables containing widgets) ended up routed to
-- whichever renderer matched first. Parsing to a tree lets the renderer
-- decide per node instead of per payload.
--
-- Node shapes:
--   element: { tag = "marimo-tabs", attrs = {…}, attr_str = "…", children = {…} }
--   text:    { text = "raw text (entities still encoded)" }
--
-- `attrs` values are entity-decoded for direct use. `attr_str` keeps the raw
-- attribute substring so `serialize(node)` can reconstruct the *exact*
-- original HTML for a subtree — that's what lets node subtrees feed the
-- existing string-based consumers (dataframe.extract_from_html,
-- markdown.render, image.extract_*) without re-encoding round-trips.

local M = {}

-- Payloads beyond this size skip tree parsing (callers fall back to a
-- placeholder). Plotly figures embed their data as JSON attributes and can
-- reach megabytes; parsing is O(n) but there's no point building a tree we
-- would only render as one placeholder line anyway.
M.MAX_PARSE_BYTES = 2 * 1024 * 1024

-- ── entities ──────────────────────────────────────────────────────────────

local NAMED_ENTITIES = {
  ["&amp;"] = "&",
  ["&lt;"] = "<",
  ["&gt;"] = ">",
  ["&quot;"] = '"',
  ["&apos;"] = "'",
  ["&nbsp;"] = " ",
  ["&hellip;"] = "…",
  ["&mdash;"] = "—",
  ["&ndash;"] = "–",
  ["&copy;"] = "©",
  ["&trade;"] = "™",
  ["&reg;"] = "®",
}

-- Decode named entities plus generic numeric character references. The
-- numeric pass matters for marimo payloads: nested-JSON attribute values
-- entity-encode their escaping backslashes as &#92; (and quotes as &#x27;),
-- so without it a JSON decode downstream sees `&#92;"` and bails.
function M.decode_entities(s)
  if type(s) ~= "string" then return s end
  s = s:gsub("&%w+;", function(e) return NAMED_ENTITIES[e] or e end)
  s = s:gsub("&#x(%x+);", function(hex)
    local n = tonumber(hex, 16)
    if n then return vim.fn.nr2char(n) end
  end)
  s = s:gsub("&#(%d+);", function(dec)
    local n = tonumber(dec)
    if n then return vim.fn.nr2char(n) end
  end)
  return s
end

-- ── attributes ────────────────────────────────────────────────────────────

-- Parse a `key="value"` / `key='value'` / `key=value` attribute string into
-- a table of entity-decoded values. Marimo single-quotes its attributes,
-- pandas double-quotes; both appear in real payloads.
function M.parse_attrs(attr_str)
  local out = {}
  if type(attr_str) ~= "string" then return out end
  for k, v in attr_str:gmatch('([%w%-_:]+)%s*=%s*"([^"]*)"') do
    out[k] = M.decode_entities(v)
  end
  for k, v in attr_str:gmatch("([%w%-_:]+)%s*=%s*'([^']*)'") do
    if out[k] == nil then out[k] = M.decode_entities(v) end
  end
  for k, v in attr_str:gmatch("([%w%-_:]+)%s*=%s*([^%s'\"=<>`]+)") do
    if out[k] == nil then out[k] = M.decode_entities(v) end
  end
  return out
end

-- Decode an attribute value that holds JSON. Values coming out of
-- parse_attrs are already entity-decoded, so this is just a JSON decode —
-- plus the unwrap for marimo's double-encoded shape, where the attribute
-- holds a JSON *string* whose content is itself JSON (data-data on
-- marimo-table, data-tabs on marimo-tabs, …).
function M.json_attr(s)
  if type(s) ~= "string" or s == "" then return nil end
  local ok, data = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  if not ok then return nil end
  if type(data) == "string" then
    local ok2, data2 = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
    if ok2 then return data2 end
  end
  return data
end

-- Clean up a string that marimo triple-wrapped: HTML-attribute-encoded ⇒
-- JSON-string ⇒ markdown-rendered HTML. Widget labels and tab/accordion
-- labels all arrive in this shape; we undo all three layers so the user
-- sees "alpha", not `"<span class=\"markdown prose…\">alpha</span>"`.
function M.clean_label(s)
  if type(s) ~= "string" or s == "" then return s end
  s = M.decode_entities(s)
  -- Unlabeled widgets carry the JSON literal `null` — treat as no label.
  if s == "null" then return nil end
  if s:sub(1, 1) == '"' and s:sub(-1) == '"' then
    local ok, decoded = pcall(vim.json.decode, s)
    if ok and type(decoded) == "string" then s = decoded end
  end
  s = s:gsub("<[^>]+>", "")
  s = s:match("^%s*(.-)%s*$") or s
  return s
end

-- Best-effort unmarshal for marimo's `data-initial-value` payload, which is
-- sometimes a bare primitive and sometimes JSON-encoded (dropdown and
-- multiselect carry arrays). Returns the parsed value, falling back to the
-- raw string.
function M.parse_initial_value(raw)
  if raw == nil then return nil end
  if raw == "true" then return true end
  if raw == "false" then return false end
  local n = tonumber(raw)
  if n then return n end
  if raw:sub(1, 1) == "[" or raw:sub(1, 1) == "{" or raw:sub(1, 1) == '"' then
    local ok, data = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
    if ok then return data end
  end
  return raw
end

-- ── parser ────────────────────────────────────────────────────────────────

-- Elements that never have children / a closing tag.
local VOID = {
  area = true, base = true, br = true, col = true, embed = true, hr = true,
  img = true, input = true, link = true, meta = true, source = true,
  track = true, wbr = true,
}

-- Elements whose body is raw text up to the literal closing tag (no nested
-- element parsing). Plotly/vega payloads can carry these.
local RAW_TEXT = { script = true, style = true }

-- Find the `>` that ends the tag opened at `start`, skipping any `>` inside
-- quoted attribute values (legal HTML, even though marimo entity-encodes).
local function find_tag_end(s, start)
  local i, n = start, #s
  local quote = nil
  while i <= n do
    local c = s:sub(i, i)
    if quote then
      if c == quote then quote = nil end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == ">" then
      return i
    end
    i = i + 1
  end
  return nil
end

-- Parse `html` into a tree rooted at a synthetic `#root` node. Never raises;
-- malformed input degrades to text nodes / auto-closed elements. Returns
-- (root, err) — err is non-nil only for oversized or non-string input, in
-- which case root is an empty tree.
function M.parse(html)
  local root = { tag = "#root", attrs = {}, attr_str = "", children = {} }
  if type(html) ~= "string" then return root, "not a string" end
  if #html > M.MAX_PARSE_BYTES then return root, "payload too large" end

  local stack = { root }
  local function top() return stack[#stack] end
  local function push_text(text)
    if text ~= "" then table.insert(top().children, { text = text }) end
  end

  local i, n = 1, #html
  while i <= n do
    local lt = html:find("<", i, true)
    if not lt then
      push_text(html:sub(i))
      break
    end
    if lt > i then push_text(html:sub(i, lt - 1)) end

    local nxt = html:sub(lt + 1, lt + 1)

    if html:sub(lt, lt + 3) == "<!--" then
      -- Comment: skip to -->; unterminated comment swallows the rest.
      local close = html:find("-->", lt + 4, true)
      i = close and (close + 3) or (n + 1)

    elseif nxt == "/" then
      -- Closing tag. Pop the stack to the matching opener, implicitly
      -- closing anything unclosed above it. A stray closer with no matching
      -- opener is ignored.
      local gt = html:find(">", lt, true)
      if not gt then break end
      local name = html:sub(lt + 2, gt - 1):match("^%s*([%w%-]+)")
      if name then
        name = name:lower()
        for d = #stack, 2, -1 do
          if stack[d].tag == name then
            for _ = #stack, d, -1 do table.remove(stack) end
            break
          end
        end
      end
      i = gt + 1

    elseif nxt:match("%a") or html:sub(lt + 1, lt + 1) == "!" then
      -- Opening tag (or doctype, which we treat as a void element and drop).
      local gt = find_tag_end(html, lt)
      if not gt then
        -- Unterminated tag at EOF: keep it as literal text so nothing is
        -- silently swallowed.
        push_text(html:sub(lt))
        break
      end
      local inner = html:sub(lt + 1, gt - 1)
      local self_closing = inner:sub(-1) == "/"
      if self_closing then inner = inner:sub(1, -2) end
      local name, attr_str = inner:match("^([%w%-]+)(.*)$")
      if not name or name:sub(1, 1) == "!" then
        i = gt + 1
      else
        name = name:lower()
        local node = {
          tag = name,
          attrs = M.parse_attrs(attr_str),
          attr_str = attr_str or "",
          self_closing = self_closing or nil,
          children = {},
        }
        table.insert(top().children, node)
        if RAW_TEXT[name] and not self_closing then
          -- Raw-text element: body is literal text up to the closing tag.
          local close = html:find("</" .. name, gt + 1, true)
          local body_end = close and (close - 1) or n
          local body = html:sub(gt + 1, body_end)
          if body ~= "" then table.insert(node.children, { text = body }) end
          local close_gt = close and html:find(">", close, true)
          i = close_gt and (close_gt + 1) or (n + 1)
        else
          if not self_closing and not VOID[name] then
            table.insert(stack, node)
          end
          i = gt + 1
        end
      end

    else
      -- "<" followed by junk (e.g. "a < b" in prose): literal text.
      push_text("<")
      i = lt + 1
    end
  end

  return root
end

-- ── tree utilities ────────────────────────────────────────────────────────

function M.is_element(node)
  return type(node) == "table" and node.tag ~= nil
end

function M.is_text(node)
  return type(node) == "table" and node.text ~= nil
end

-- Element children only (skips text nodes).
function M.element_children(node)
  local out = {}
  for _, c in ipairs(node.children or {}) do
    if M.is_element(c) then table.insert(out, c) end
  end
  return out
end

-- Depth-first search for the first element satisfying `pred(node)`.
-- Includes `node` itself.
function M.find_first(node, pred)
  if M.is_element(node) then
    if pred(node) then return node end
    for _, c in ipairs(node.children) do
      local hit = M.find_first(c, pred)
      if hit then return hit end
    end
  end
  return nil
end

-- True if any element in the subtree satisfies `pred`.
function M.any(node, pred)
  return M.find_first(node, pred) ~= nil
end

-- Concatenated, entity-decoded text content of a subtree.
function M.text_content(node)
  if M.is_text(node) then return M.decode_entities(node.text) end
  if not M.is_element(node) then return "" end
  local parts = {}
  for _, c in ipairs(node.children) do
    table.insert(parts, M.text_content(c))
  end
  return table.concat(parts)
end

-- Reconstruct the exact original HTML for a subtree. Possible because
-- elements keep their raw `attr_str` (plus a self_closing flag) and text
-- nodes keep raw (still-encoded) text. Comments and doctypes are the only
-- input not reproduced — they're dropped at parse time.
function M.serialize(node)
  if M.is_text(node) then return node.text end
  if not M.is_element(node) then return "" end

  local parts = {}
  local function walk(nd)
    if M.is_text(nd) then
      table.insert(parts, nd.text)
      return
    end
    if nd.tag ~= "#root" then
      if nd.self_closing then
        table.insert(parts, "<" .. nd.tag .. nd.attr_str .. "/>")
      else
        table.insert(parts, "<" .. nd.tag .. nd.attr_str .. ">")
      end
    end
    for _, c in ipairs(nd.children) do walk(c) end
    if nd.tag ~= "#root" and not VOID[nd.tag] and not nd.self_closing then
      table.insert(parts, "</" .. nd.tag .. ">")
    end
  end
  walk(node)
  return table.concat(parts)
end

return M

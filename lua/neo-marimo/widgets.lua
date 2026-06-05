-- Phase 8.3 — interactive widget rendering for mo.ui.* outputs.
--
-- Marimo serializes UI elements as `<marimo-{name} object-id="…"
-- data-{attr}="…" …>` custom elements inside the cell's HTML payload. We
-- parse those out, render an ASCII representation, and keep a registry per
-- cell so :MarimoWidget can list them and POST value updates to the kernel
-- via /api/kernel/set_ui_element_value.
--
-- Why a side command instead of cursor-on-row keymaps:
--   Virt_lines don't accept cursor focus, so the plan's "key dispatcher
--   keyed on cursor row" can't reach a widget that lives entirely inside
--   a virt_line attached to the cell's end_row. We expose interaction via
--   `:MarimoWidget` (and `<leader>mw` by default), which opens a picker for
--   the widgets in the current cell's output. The picker drives the same
--   set_ui_element_value endpoint the browser uses, so dependent cells
--   re-run as soon as a value changes.

local utils = require("neo-marimo.utils")

local M = {}

-- ── per-notebook widget registry ──────────────────────────────────────────
--
-- Keyed by (bufnr, cell_id) so cell-op re-renders blow away the old set
-- before the new one lands. Widget table fields:
--   name           - "slider", "button", "checkbox", etc.
--   object_id      - marimo's stable id for set_ui_element_value
--   value          - current value (best-effort from data-initial-value)
--   options        - parsed attribute map (start, stop, step, label, …)
--   label          - human-readable label for pickers

M._by_cell = {}

local function registry_key(bufnr, cell_id) return bufnr .. ":" .. cell_id end

function M.clear_for_cell(bufnr, cell_id)
  M._by_cell[registry_key(bufnr, cell_id)] = nil
end

function M.list_for_cell(bufnr, cell_id)
  return M._by_cell[registry_key(bufnr, cell_id)] or {}
end

local function register(bufnr, cell_id, widget)
  local key = registry_key(bufnr, cell_id)
  M._by_cell[key] = M._by_cell[key] or {}
  table.insert(M._by_cell[key], widget)
end

-- ── HTML helpers ──────────────────────────────────────────────────────────

local function decode_entities(s)
  if type(s) ~= "string" then return s end
  return (s:gsub("&amp;", "&")
           :gsub("&lt;", "<")
           :gsub("&gt;", ">")
           :gsub("&quot;", '"')
           :gsub("&#39;", "'")
           :gsub("&apos;", "'"))
end

-- Parse a key="value" / key='value' / key=value (unquoted) attribute string
-- into a Lua table. Marimo's HTML is well-formed so we don't need to handle
-- broken markup — but we do see both quoting styles depending on what's
-- inside the value.
local function parse_attrs(attr_str)
  local out = {}
  for k, v in attr_str:gmatch('([%w%-_:]+)%s*=%s*"([^"]*)"') do
    out[k] = decode_entities(v)
  end
  for k, v in attr_str:gmatch("([%w%-_:]+)%s*=%s*'([^']*)'") do
    if out[k] == nil then out[k] = decode_entities(v) end
  end
  return out
end

local function to_num(s, default)
  if s == nil then return default end
  return tonumber(s) or default
end

local function to_bool(s, default)
  if s == nil then return default end
  if s == "true" or s == "1" or s == "yes" then return true end
  if s == "false" or s == "0" or s == "no" then return false end
  return default
end

-- Best-effort JSON unmarshal for marimo's `data-initial-value` payload,
-- which is sometimes a primitive string and sometimes a JSON-encoded one
-- (e.g. for dropdown/multiselect that carry arrays). Returns the parsed
-- value, falling back to the raw string.
local function parse_initial_value(raw)
  if raw == nil then return nil end
  if raw == "true" then return true end
  if raw == "false" then return false end
  local n = tonumber(raw)
  if n then return n end
  -- Looks like JSON?
  if raw:sub(1, 1) == "[" or raw:sub(1, 1) == "{" or raw:sub(1, 1) == '"' then
    local data, err = utils.json_decode(raw)
    if not err then return data end
  end
  return raw
end

-- ── per-type renderers ────────────────────────────────────────────────────
--
-- Each renderer takes the parsed widget table and returns a list of virt_line
-- chunks (i.e. a list of {text, hl_group}-tuple lists). Multi-line widgets
-- (text_area, dropdown with picker indicator) emit several lines.

local function render_slider(w)
  local start = w.options.start or 0
  local stop = w.options.stop or 1
  local value = tonumber(w.value) or start
  local label = w.options.label or "slider"

  local width = 24
  local denom = (stop - start)
  local pos = 0
  if denom ~= 0 then
    pos = math.floor(((value - start) / denom) * (width - 1) + 0.5)
    if pos < 0 then pos = 0 end
    if pos > width - 1 then pos = width - 1 end
  end

  local before = string.rep("━", pos)
  local thumb = "●"
  local after = string.rep("━", width - pos - 1)

  return { {
    { "  ", "MarimoOutputText" },
    { label .. ": ", "MarimoWidgetLabel" },
    { "[", "MarimoWidgetTrack" },
    { before, "MarimoWidgetTrack" },
    { thumb, "MarimoWidgetThumb" },
    { after, "MarimoWidgetTrack" },
    { "] ", "MarimoWidgetTrack" },
    { tostring(value), "MarimoWidgetValue" },
    { "  (" .. start .. "‥" .. stop .. ")", "Comment" },
  } }
end

local function render_button(w)
  local label = w.options.label or w.options.kind or "Click"
  return { {
    { "  ", "MarimoOutputText" },
    { " " .. label .. " ", "MarimoWidgetButton" },
    { "  press via :MarimoWidget", "Comment" },
  } }
end

local function render_checkbox(w)
  local checked = to_bool(tostring(w.value), false)
  local label = w.options.label or "checkbox"
  local mark = checked and "[x]" or "[ ]"
  return { {
    { "  ", "MarimoOutputText" },
    { mark, "MarimoWidgetThumb" },
    { " " .. label, "MarimoWidgetLabel" },
  } }
end

local function render_text(w)
  local label = w.options.label or "text"
  local value = tostring(w.value or "")
  return { {
    { "  ", "MarimoOutputText" },
    { label .. ": ", "MarimoWidgetLabel" },
    { "[ ", "MarimoWidgetBoxBorder" },
    { value ~= "" and value or "…", "MarimoWidgetValue" },
    { " ]", "MarimoWidgetBoxBorder" },
  } }
end

local function render_text_area(w)
  local label = w.options.label or "text_area"
  local value = tostring(w.value or "")
  local lines = vim.split(value, "\n", { plain = true })

  local width = 40
  for _, l in ipairs(lines) do
    if #l + 4 > width then width = math.min(80, #l + 4) end
  end

  local out = {
    { { "  ", "MarimoOutputText" },
      { label, "MarimoWidgetLabel" } },
    { { "  ╭" .. string.rep("─", width - 2) .. "╮", "MarimoWidgetBoxBorder" } },
  }
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    table.insert(out, {
      { "  │ ", "MarimoWidgetBoxBorder" },
      { "…", "Comment" },
      { string.rep(" ", width - 5), "MarimoWidgetBoxBorder" },
      { "│", "MarimoWidgetBoxBorder" },
    })
  else
    for _, line in ipairs(lines) do
      local visible = line:sub(1, width - 4)
      local pad = string.rep(" ", math.max(0, width - 4 - #visible))
      table.insert(out, {
        { "  │ ", "MarimoWidgetBoxBorder" },
        { visible, "MarimoWidgetValue" },
        { pad, "MarimoWidgetBoxBorder" },
        { " │", "MarimoWidgetBoxBorder" },
      })
    end
  end
  table.insert(out, { { "  ╰" .. string.rep("─", width - 2) .. "╯", "MarimoWidgetBoxBorder" } })
  return out
end

local function render_dropdown(w)
  local label = w.options.label or "dropdown"
  local value = w.value
  if type(value) == "table" then value = value[1] or "" end
  return { {
    { "  ", "MarimoOutputText" },
    { label .. ": ", "MarimoWidgetLabel" },
    { "[ ", "MarimoWidgetBoxBorder" },
    { tostring(value or "…"), "MarimoWidgetValue" },
    { " ▾ ]", "MarimoWidgetBoxBorder" },
  } }
end

local function render_multiselect(w)
  local label = w.options.label or "multiselect"
  local value = w.value
  local repr
  if type(value) == "table" then
    repr = table.concat(value, ", ")
    if repr == "" then repr = "…" end
  else
    repr = tostring(value or "…")
  end
  return { {
    { "  ", "MarimoOutputText" },
    { label .. ": ", "MarimoWidgetLabel" },
    { "[ ", "MarimoWidgetBoxBorder" },
    { repr, "MarimoWidgetValue" },
    { " ▾ ]", "MarimoWidgetBoxBorder" },
  } }
end

local function render_number(w)
  local label = w.options.label or "number"
  return { {
    { "  ", "MarimoOutputText" },
    { label .. ": ", "MarimoWidgetLabel" },
    { "[ ", "MarimoWidgetBoxBorder" },
    { tostring(w.value or 0), "MarimoWidgetValue" },
    { " ]", "MarimoWidgetBoxBorder" },
  } }
end

local function render_date(w)
  local label = w.options.label or "date"
  return { {
    { "  ", "MarimoOutputText" },
    { label .. ": ", "MarimoWidgetLabel" },
    { "[ ", "MarimoWidgetBoxBorder" },
    { tostring(w.value or "…"), "MarimoWidgetValue" },
    { " 📅 ]", "MarimoWidgetBoxBorder" },
  } }
end

local function render_radio(w)
  local label = w.options.label or "radio"
  return { {
    { "  ", "MarimoOutputText" },
    { label .. ": ", "MarimoWidgetLabel" },
    { "(•) ", "MarimoWidgetThumb" },
    { tostring(w.value or "…"), "MarimoWidgetValue" },
  } }
end

local function render_unknown(w)
  return { {
    { "  ", "MarimoOutputText" },
    { "[" .. w.name .. "]", "MarimoWidgetLabel" },
    { " value=", "Comment" },
    { tostring(w.value or "?"), "MarimoWidgetValue" },
  } }
end

-- Renderer table keyed on the widget name. `name` here is the suffix of
-- `<marimo-{name}>` (e.g. "slider", "text-area"). Marimo uses kebab-case
-- in tag names but snake_case in the Python API; we normalise via
-- `name:gsub("-", "_")` before lookup.
local RENDERERS = {
  slider       = render_slider,
  button       = render_button,
  checkbox     = render_checkbox,
  text         = render_text,
  text_area    = render_text_area,
  dropdown     = render_dropdown,
  multiselect  = render_multiselect,
  number       = render_number,
  date         = render_date,
  datetime     = render_date,
  radio        = render_radio,
  range_slider = render_slider,
  switch       = render_checkbox,
}

-- ── parsing pass ──────────────────────────────────────────────────────────

local WIDGET_PATTERN = "<marimo%-([%w%-]+)([^>]*)>"

-- Extract widgets from an HTML payload. Returns:
--   widgets : list of parsed widget tables
--   stripped: html with the widget tags substituted by ASCII placeholders
--             ("[slider]") so any surrounding text/structure renders cleanly.
local function parse_widgets(html)
  local widgets = {}
  local stripped = html:gsub(WIDGET_PATTERN, function(name, attr_str)
    local attrs = parse_attrs(attr_str)
    local key = name:gsub("-", "_")
    local options = {}
    for k, v in pairs(attrs) do
      if k:sub(1, 5) == "data-" then
        options[k:sub(6):gsub("%-", "_")] = v
      end
    end
    if options.start then options.start = to_num(options.start, options.start) end
    if options.stop  then options.stop  = to_num(options.stop,  options.stop)  end
    if options.step  then options.step  = to_num(options.step,  options.step)  end

    local w = {
      name = key,
      object_id = attrs["object-id"] or attrs.object_id,
      label = options.label or key,
      value = parse_initial_value(options.initial_value),
      options = options,
    }
    table.insert(widgets, w)
    return "[" .. key .. "]"
  end)

  -- Also close any trailing </marimo-name> tags now that we've stripped
  -- the opener — leaving them in would show as literal "</marimo-slider>".
  stripped = stripped:gsub("</marimo%-[%w%-]+>", "")
  return widgets, stripped
end

-- ── Phase 8.4 layout primitives ───────────────────────────────────────────
--
-- mo.hstack / mo.vstack / mo.tabs / mo.accordion render as ASCII boxes. The
-- layouts share the same HTML rail as widgets (custom elements + helper
-- divs), so detection lives next to the widget parser and the renderer is
-- recursive: a layout's children may contain more layouts or widgets.

local LAYOUT_PATTERN = "<marimo%-(h?vstack)([^>]*)>(.-)</marimo%-%1>"

-- Walk a layout's inner HTML, breaking it into "slot" strings on the
-- top-level child elements. Marimo wraps each child in a `<div>` or
-- another `<marimo-*>` element, so we match balanced angle-bracket pairs.
-- A real HTML parser would be safer; this regex chain handles the layouts
-- marimo emits because they don't nest plain `<` inside attribute values.
local function split_layout_children(inner)
  local children = {}
  local i = 1
  while i <= #inner do
    -- Skip whitespace between children.
    local s, e = inner:find("^%s+", i)
    if s then i = e + 1 end

    -- Match either a <marimo-*>…</marimo-*> child or a <div …>…</div> child.
    local tag_open = inner:match("^<([%w%-]+)", i)
    if not tag_open then break end
    local close_tag = "</" .. tag_open .. ">"
    local content_start = inner:find(">", i, true)
    if not content_start then break end
    local content_end = inner:find(close_tag, content_start + 1, true)
    if not content_end then break end
    table.insert(children, inner:sub(content_start + 1, content_end - 1))
    i = content_end + #close_tag
  end
  return children
end

-- Render a vertical stack: each child is a block of virt_lines, separated
-- by a blank-ish spacer so the user can tell where one ends and the next
-- starts.
local function render_vstack(_attrs, inner, ctx)
  local out = {}
  local children = split_layout_children(inner)
  for idx, child in ipairs(children) do
    local lines = M.render(child, ctx.bufnr, ctx.cell_id) or {}
    for _, l in ipairs(lines) do table.insert(out, l) end
    if idx < #children then
      table.insert(out, { { "  ", "MarimoOutputText" } })
    end
  end
  return out
end

-- Render a horizontal stack as side-by-side ASCII boxes. Each child is
-- rendered into its own list of virt_line chunks, then stitched into a
-- column. Width is computed from the surrounding window, capped so each
-- column gets at least 12 visible characters.
local function render_hstack(_attrs, inner, ctx)
  local children = split_layout_children(inner)
  if #children == 0 then return {} end

  -- Render each child into a string-only column. We can't carry per-character
  -- highlights through a side-by-side stitch without exploding the chunk
  -- count, so the column body uses MarimoOutputText. The border keeps its
  -- own colour.
  local columns = {}
  local max_height = 0
  local total_pad = 4   -- two outer spaces + the leading "  " indent
  for _, child in ipairs(children) do
    local virt = M.render(child, ctx.bufnr, ctx.cell_id) or {}
    local strs = {}
    for _, chunks in ipairs(virt) do
      local s = ""
      for _, ch in ipairs(chunks) do s = s .. ch[1] end
      -- Drop the leading two-space indent each renderer adds, otherwise
      -- it stacks and the columns are pushed off the right edge.
      s = s:gsub("^%s%s", "")
      table.insert(strs, s)
    end
    table.insert(columns, strs)
    if #strs > max_height then max_height = #strs end
  end

  local wins = vim.fn.win_findbuf(ctx.bufnr or 0)
  local total_width = 80
  if #wins > 0 then total_width = vim.api.nvim_win_get_width(wins[1]) end
  local col_width = math.max(12, math.floor((total_width - total_pad - 4) / #columns))

  local out = {}
  local top = "  "
  local bot = "  "
  for j = 1, #columns do
    top = top .. (j == 1 and "┌" or "┬") .. string.rep("─", col_width)
  end
  top = top .. "┐"
  for j = 1, #columns do
    bot = bot .. (j == 1 and "└" or "┴") .. string.rep("─", col_width)
  end
  bot = bot .. "┘"

  -- Truncate a string to fit within `cells` display cells without slicing
  -- through a multi-byte codepoint. Box-drawing chars are 3 bytes / 1 cell
  -- so a naïve s:sub(1, n) lops them in half and shows replacement glyphs.
  -- vim.fn.strcharpart counts in codepoints, then we measure display width
  -- after the fact.
  local function fit(s, cells)
    local total_chars = vim.fn.strchars(s)
    local lo, hi = 0, total_chars
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      local candidate = vim.fn.strcharpart(s, 0, mid)
      if vim.fn.strdisplaywidth(candidate) <= cells then
        lo = mid
      else
        hi = mid - 1
      end
    end
    local fitted = vim.fn.strcharpart(s, 0, lo)
    return fitted, vim.fn.strdisplaywidth(fitted)
  end

  table.insert(out, { { top, "MarimoWidgetBoxBorder" } })
  for row = 1, max_height do
    local chunks = { { "  ", "MarimoOutputText" } }
    for j, col in ipairs(columns) do
      table.insert(chunks, { "│", "MarimoWidgetBoxBorder" })
      local cell = col[row] or ""
      local visible, visible_w = fit(cell, col_width - 1)
      local pad = string.rep(" ", math.max(0, col_width - 1 - visible_w))
      table.insert(chunks, { " ", "MarimoOutputText" })
      table.insert(chunks, { visible, "MarimoOutputText" })
      table.insert(chunks, { pad, "MarimoOutputText" })
      if j == #columns then
        table.insert(chunks, { "│", "MarimoWidgetBoxBorder" })
      end
    end
    table.insert(out, chunks)
  end
  table.insert(out, { { bot, "MarimoWidgetBoxBorder" } })
  return out
end

-- Tabs: marimo emits a list of <marimo-tab-content data-label="…">…</…>
-- entries. Render every tab in vertical succession with a labeled divider —
-- the alternative (showing only the first tab plus a "switch with <Tab>"
-- hint) requires cursor focus on a virt_line, which doesn't work.
local function render_tabs(_attrs, inner, _ctx)
  local tabs = {}
  for label, body in inner:gmatch('<marimo%-tab%-content[^>]*data%-label="([^"]*)"[^>]*>(.-)</marimo%-tab%-content>') do
    table.insert(tabs, { label = label, body = body })
  end
  if #tabs == 0 then return {} end

  local out = {}
  for i, tab in ipairs(tabs) do
    local hl_group = i == 1 and "MarimoWidgetTabActive" or "MarimoWidgetTabInactive"
    table.insert(out, { { "  ", "MarimoOutputText" },
                        { "▎ tab: ", "MarimoWidgetBoxBorder" },
                        { tab.label, hl_group } })
    local body_lines = M.render(tab.body) or {}
    for _, l in ipairs(body_lines) do table.insert(out, l) end
    if i < #tabs then table.insert(out, { { "  ", "MarimoOutputText" } }) end
  end
  return out
end

-- Accordion: each `<marimo-accordion-item data-label="…">…</…>` becomes a
-- collapsed header followed by its body inline. Real fold-style collapsing
-- isn't worth it inside virt_lines.
local function render_accordion(_attrs, inner, _ctx)
  local out = {}
  for label, body in inner:gmatch('<marimo%-accordion%-item[^>]*data%-label="([^"]*)"[^>]*>(.-)</marimo%-accordion%-item>') do
    table.insert(out, { { "  ", "MarimoOutputText" },
                        { "▾ ", "MarimoWidgetBoxBorder" },
                        { label, "MarimoWidgetLabel" } })
    local body_lines = M.render(body) or {}
    for _, l in ipairs(body_lines) do
      -- Re-indent the body so it visually belongs to the header.
      table.insert(out, l)
    end
  end
  return out
end

local LAYOUTS = {
  ["marimo%-hstack"]    = render_hstack,
  ["marimo%-vstack"]    = render_vstack,
  ["marimo%-tabs"]      = render_tabs,
  ["marimo%-accordion"] = render_accordion,
}

-- Strip one (and only one) layout wrapper from `html`, returning the
-- inner body and the renderer function — or nil if no layout matches.
local function try_match_layout(html)
  for tag, fn in pairs(LAYOUTS) do
    local open, attr_str, inner_start = html:match("^%s*(<" .. tag .. ")(([^>]*))>")
    if open then
      local content_start = html:find(">", 1, true)
      local close_tag = "</" .. tag:gsub("%%", "") .. ">"
      local content_end = html:find(close_tag, content_start + 1, true)
      if content_end then
        local inner = html:sub(content_start + 1, content_end - 1)
        return fn, attr_str or "", inner
      end
    end
  end
  return nil
end

-- ── public API ────────────────────────────────────────────────────────────

-- True if the html payload contains any marimo widget custom elements.
function M.has_widgets(html)
  if type(html) ~= "string" then return false end
  return html:find(WIDGET_PATTERN) ~= nil
end

-- True if the html payload is wrapped in a layout primitive that we render
-- (hstack/vstack/tabs/accordion). Containers without recognised children
-- still match — the renderer falls through to the widget pass on the body.
function M.has_layout(html)
  if type(html) ~= "string" then return false end
  return html:find("<marimo%-hstack") ~= nil
      or html:find("<marimo%-vstack") ~= nil
      or html:find("<marimo%-tabs") ~= nil
      or html:find("<marimo%-accordion") ~= nil
end

-- Render `html` (containing any combination of marimo widgets and/or
-- layout primitives) into virt_line chunks. Also registers each parsed
-- widget with the (bufnr, cell_id) cell-scoped registry so :MarimoWidget
-- can act on it.
--
-- `bufnr` and `cell_id` are optional — only the outermost call clears the
-- cell registry; recursive calls from layout renderers reuse the same ctx
-- so children widgets accumulate into the same registry list.
function M.render(html, bufnr, cell_id)
  if type(html) ~= "string" then return {} end

  -- Track recursion: only the *outermost* render call should clear the
  -- cell registry and reset the in-render flag. A naïve boolean guard
  -- would let recursive sibling calls inside an hstack/vstack each clear
  -- the registry between iterations, dropping every widget but the last.
  local is_outer = false
  if bufnr and cell_id and not M._in_render then
    M.clear_for_cell(bufnr, cell_id)
    M._in_render = true
    is_outer = true
  end

  local ctx = { bufnr = bufnr, cell_id = cell_id }

  -- Layout match: render the wrapper and return early. The inner body is
  -- rendered recursively (which may itself match a layout, hit widgets, or
  -- both).
  local layout_fn, attr_str, inner = try_match_layout(html)
  if layout_fn then
    local out = layout_fn(attr_str, inner, ctx)
    if is_outer then M._in_render = false end
    return out
  end

  local widgets, stripped = parse_widgets(html)
  local virt_lines = {}
  for _, w in ipairs(widgets) do
    if bufnr and cell_id then register(bufnr, cell_id, w) end
    local renderer = RENDERERS[w.name] or render_unknown
    local chunks_list = renderer(w)
    for _, chunks in ipairs(chunks_list) do
      table.insert(virt_lines, chunks)
    end
  end

  -- If there's residual non-tag text (e.g. a label paragraph that wrapped
  -- the widget), append it as a final dim line so we don't lose context.
  local trimmed = stripped:gsub("<[^>]+>", ""):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
  for _, w in ipairs(widgets) do
    trimmed = trimmed:gsub("%[" .. w.name .. "%]", "")
  end
  trimmed = trimmed:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
  if trimmed ~= "" then
    table.insert(virt_lines, {
      { "  ", "MarimoOutputText" },
      { trimmed, "Comment" },
    })
  end

  if is_outer then M._in_render = false end
  return virt_lines
end

-- POST a new value for a widget to /api/kernel/set_ui_element_value. Returns
-- true on success. The server replies with cell-op updates for any cell that
-- depends on this widget, so the user sees re-runs in the cell output area.
function M.set_value(filepath, object_id, value)
  local server = require("neo-marimo.server")
  local srv = server._servers and server._servers[filepath]
  if not srv then
    utils.warn("No server running for this notebook — cannot set widget value.")
    return false
  end

  local http_post = server._http_post
  if not http_post then
    -- server.lua keeps http_post private. Re-implement the minimal call here
    -- via vim.system + curl so we don't have to widen the API surface.
    local body = vim.json.encode({
      object_ids = { object_id },
      values     = { value },
    })
    local args = {
      "curl", "-s", "--max-time", "10", "-X", "POST",
      "-H", "Content-Type: application/json",
      "-H", "Marimo-Session-Id: " .. srv.session_id,
    }
    if srv.server_token then
      table.insert(args, "-H")
      table.insert(args, "Marimo-Server-Token: " .. srv.server_token)
    end
    table.insert(args, "-d"); table.insert(args, body)
    table.insert(args, "http://127.0.0.1:" .. tostring(srv.port)
                       .. "/api/kernel/set_ui_element_value")
    local r = vim.system(args, { text = true }):wait()
    return r.code == 0
  end
end

-- Build a human-readable list-row label for use in pickers.
function M.describe(w)
  if w.name == "slider" then
    return string.format("slider · %s = %s (%s‥%s)",
      w.label, tostring(w.value), tostring(w.options.start), tostring(w.options.stop))
  elseif w.name == "checkbox" or w.name == "switch" then
    return string.format("%s · %s = %s", w.name, w.label, tostring(w.value))
  elseif w.name == "button" then
    return string.format("button · %s", w.label)
  else
    return string.format("%s · %s = %s", w.name, w.label, tostring(w.value))
  end
end

return M

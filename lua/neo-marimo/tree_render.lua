-- Phase 9.2 — node-walking renderer for marimo HTML payloads.
--
-- output.lua routes any text/html payload that carries marimo custom
-- elements, an HTML <table>, or a flex layout here. The payload is parsed
-- once into an element tree (html.lua) and rendered by walking nodes, so
-- routing decisions happen per element instead of first-match-wins on the
-- whole payload — a tabs container holding a table renders as tabs *with* a
-- table inside, rather than the table hijacking the entire cell (the old
-- behavior on notebooks/notebook.py cell 4).
--
-- Subtrees that belong to an existing string-based renderer (dataframe
-- extraction, markdown, images) are handed over via html.serialize(node),
-- which reconstructs the exact original substring (round-trip-tested over
-- the fixture corpus), so those renderers didn't have to change.
--
-- ctx fields (shared with output.lua's _render_ctx):
--   bufnr, cell_id   widget registry key + image placement key
--   row              0-indexed row images anchor at
--   filepath         notebook path, for server-hosted virtual files
--   image_drawn      out-param: an inline image placement was created
--   skip_cap         out-param: payload renders widgets/layouts, don't
--                    truncate at MAX_LINES
--   object_id        transient: the <marimo-ui-element> wrapper id in scope

local html = require("neo-marimo.html")
local widgets = require("neo-marimo.widgets")
local dataframe = require("neo-marimo.dataframe")
local markdown = require("neo-marimo.markdown")
local image = require("neo-marimo.image")

local M = {}

-- ── routing predicate ─────────────────────────────────────────────────────

-- True when the payload should take the tree path. Anything else keeps
-- output.lua's fast string path (markdown wrappers, plain images, text).
function M.wants(data)
  if type(data) ~= "string" then return false end
  return data:find("<marimo%-") ~= nil
    or data:find("<table[%s>]") ~= nil
    or data:find("flex%-direction") ~= nil
end

-- ── widget tags ───────────────────────────────────────────────────────────

-- <marimo-{tag}> elements that render as interactive ASCII widgets and
-- register with the per-cell registry for :MarimoWidget.
local WIDGET_TAGS = {
  ["slider"] = true, ["range-slider"] = true,
  ["checkbox"] = true, ["switch"] = true,
  ["text"] = true, ["text-area"] = true,
  ["number"] = true,
  ["date"] = true, ["datetime"] = true,
  ["dropdown"] = true, ["multiselect"] = true, ["radio"] = true,
  ["button"] = true, ["refresh"] = true,
}

-- Elements we can't meaningfully render in a terminal. One clean line each
-- instead of unknown-widget noise; not registered with the picker because
-- there is no value a terminal interaction could sensibly set.
local PLACEHOLDER_TAGS = {
  ["vega"] = "altair chart",
  ["plotly"] = "plotly chart",
  ["data-explorer"] = "data explorer",
  ["dataframe"] = "dataframe transformer",
  ["file"] = "file upload",
  ["json-output"] = "json output",
}

-- ── small helpers ─────────────────────────────────────────────────────────

local function append_all(dst, src)
  for _, v in ipairs(src) do table.insert(dst, v) end
end

local function placeholder_line(label)
  return { { "  [", "Comment" },
           { label, "MarimoWidgetLabel" },
           { " — open in browser (<leader>mo)]", "Comment" } }
end

-- Strip-tags plain text rendering for inline HTML fragments. Mirrors
-- output.lua's fallback so prose keeps its inline flow instead of splitting
-- one line per text node.
local function render_stripped(fragment)
  local stripped = html.decode_entities(fragment:gsub("<[^>]+>", ""))
  stripped = stripped:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
  if stripped == "" then return {} end
  return { { { "  " .. stripped, "MarimoOutputText" } } }
end

-- True if the subtree has no element that needs structural rendering —
-- i.e. it is prose/markup we can hand to markdown.render or strip-tags as
-- one string without losing anything.
local function is_plain(node)
  return not html.any(node, function(n)
    return n.tag:sub(1, 7) == "marimo-"
      or n.tag == "table"
      or n.tag == "img"
      or n.tag == "svg"
      or (n.tag == "div" and (n.attrs.style or ""):find("flex%-direction"))
  end)
end

local function is_flex(node)
  if node.tag ~= "div" then return nil end
  local style = node.attrs.style or ""
  local dir = style:match("flex%-direction:%s*(%a+)")
  return dir  -- "column" | "row" | nil
end


-- ── widget construction ───────────────────────────────────────────────────

-- Build the registry/renderer widget table from a <marimo-{kind}> node.
-- The object-id comes from the enclosing <marimo-ui-element> wrapper (via
-- ctx), which the tree walk scopes naturally — no attribute-hoisting hacks.
local function widget_from_node(node, ctx)
  local key = node.tag:sub(8):gsub("%-", "_")  -- drop "marimo-"

  local options = {}
  for k, v in pairs(node.attrs) do
    if k:sub(1, 5) == "data-" then
      options[k:sub(6):gsub("%-", "_")] = v
    end
  end
  if options.start then options.start = tonumber(options.start) or options.start end
  if options.stop then options.stop = tonumber(options.stop) or options.stop end
  if options.step then options.step = tonumber(options.step) or options.step end
  if options.label then options.label = html.clean_label(options.label) end

  local object_id = node.attrs["object-id"] or ctx.object_id
  local value = html.parse_initial_value(options.initial_value)
  local override = widgets.get_override(object_id)
  if override ~= nil then value = override end

  return {
    name = key,
    object_id = object_id,
    label = (options.label and options.label ~= "") and options.label or key,
    value = value,
    options = options,
  }
end

-- ── node renderers ────────────────────────────────────────────────────────

local render_node  -- forward declaration (layout renderers recurse)

local function render_children(node, ctx)
  local out = {}
  for _, child in ipairs(node.children) do
    append_all(out, render_node(child, ctx))
  end
  return out
end

-- Vertical stack: children in sequence with a spacer line between blocks.
local function render_vstack(node, ctx)
  ctx.skip_cap = true
  local out = {}
  local blocks = {}
  for _, child in ipairs(node.children) do
    local lines = render_node(child, ctx)
    if #lines > 0 then table.insert(blocks, lines) end
  end
  for i, block in ipairs(blocks) do
    append_all(out, block)
    if i < #blocks then
      table.insert(out, { { "  ", "MarimoOutputText" } })
    end
  end
  return out
end

-- Horizontal stack: children rendered into columns and stitched
-- side-by-side inside an ASCII box. Column text loses per-chunk highlights
-- (carrying them through the stitch explodes the chunk count), border keeps
-- its own.
local function render_hstack(node, ctx)
  ctx.skip_cap = true
  local columns = {}
  local max_height = 0
  for _, child in ipairs(node.children) do
    local virt = render_node(child, ctx)
    if #virt > 0 then
      local strs = {}
      for _, chunks in ipairs(virt) do
        local s = ""
        for _, ch in ipairs(chunks) do s = s .. ch[1] end
        -- Drop the leading two-space indent each renderer adds, otherwise
        -- it stacks and pushes the columns off the right edge.
        s = s:gsub("^%s%s", "")
        table.insert(strs, s)
      end
      table.insert(columns, strs)
      if #strs > max_height then max_height = #strs end
    end
  end
  if #columns == 0 then return {} end

  local wins = vim.fn.win_findbuf(ctx.bufnr or 0)
  local total_width = 80
  if #wins > 0 then total_width = vim.api.nvim_win_get_width(wins[1]) end
  local total_pad = 4
  local col_width = math.max(12, math.floor((total_width - total_pad - 4) / #columns))

  -- Truncate to `cells` display cells without slicing a multi-byte
  -- codepoint (box-drawing chars are 3 bytes / 1 cell).
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

  local out = {}
  local top, bot = "  ", "  "
  for j = 1, #columns do
    top = top .. (j == 1 and "┌" or "┬") .. string.rep("─", col_width)
    bot = bot .. (j == 1 and "└" or "┴") .. string.rep("─", col_width)
  end
  top = top .. "┐"
  bot = bot .. "┘"

  table.insert(out, { { top, "MarimoWidgetBoxBorder" } })
  for row = 1, max_height do
    local chunks = { { "  ", "MarimoOutputText" } }
    for j, col in ipairs(columns) do
      table.insert(chunks, { "│", "MarimoWidgetBoxBorder" })
      local cell = col[row] or ""
      local visible, visible_w = fit(cell, col_width - 1)
      local pad = string.rep(" ", math.max(0, col_width - 1 - visible_w))
      table.insert(chunks, { " " .. visible .. pad, "MarimoOutputText" })
      if j == #columns then
        table.insert(chunks, { "│", "MarimoWidgetBoxBorder" })
      end
    end
    table.insert(out, chunks)
  end
  table.insert(out, { { bot, "MarimoWidgetBoxBorder" } })
  return out
end

-- Tabs: labels live in the data-tabs attribute (JSON array of
-- markdown-rendered HTML), bodies are the <div data-kind='tab'> children.
-- All tabs render stacked with a labeled divider — virt_lines can't take
-- cursor focus, so click-to-switch isn't possible.
local function render_tabs(node, ctx)
  ctx.skip_cap = true
  local labels = html.json_attr(node.attrs["data-tabs"]) or {}
  local bodies = {}
  for _, child in ipairs(html.element_children(node)) do
    if child.attrs["data-kind"] == "tab" then table.insert(bodies, child) end
  end
  if #bodies == 0 then return render_children(node, ctx) end

  local out = {}
  for i, body in ipairs(bodies) do
    local label = html.clean_label(labels[i]) or ("tab " .. i)
    local hl_group = i == 1 and "MarimoWidgetTabActive" or "MarimoWidgetTabInactive"
    table.insert(out, { { "  ", "MarimoOutputText" },
                        { "▎ tab: ", "MarimoWidgetBoxBorder" },
                        { label, hl_group } })
    append_all(out, render_children(body, ctx))
    if i < #bodies then table.insert(out, { { "  ", "MarimoOutputText" } }) end
  end
  return out
end

-- Accordion: labels in data-labels, one <div> child per section.
local function render_accordion(node, ctx)
  ctx.skip_cap = true
  local labels = html.json_attr(node.attrs["data-labels"]) or {}
  local out = {}
  for i, body in ipairs(html.element_children(node)) do
    local label = html.clean_label(labels[i]) or ("section " .. i)
    table.insert(out, { { "  ", "MarimoOutputText" },
                        { "▾ ", "MarimoWidgetBoxBorder" },
                        { label, "MarimoWidgetLabel" } })
    append_all(out, render_children(body, ctx))
  end
  return out
end

-- Callout: the body HTML hides JSON-encoded inside data-html.
local function render_callout(node, ctx)
  local kind = html.json_attr(node.attrs["data-kind"]) or "note"
  local body_html = html.json_attr(node.attrs["data-html"])
  local out = {
    { { "  ", "MarimoOutputText" },
      { "▎ ", "MarimoWidgetBoxBorder" },
      { tostring(kind), "MarimoWidgetLabel" } },
  }
  if type(body_html) == "string" and body_html ~= "" then
    append_all(out, render_node(html.parse(body_html), ctx))
  end
  return out
end

-- Form: transparent wrapper around its child widget(s), plus a submit hint.
local function render_form(node, ctx)
  local out = render_children(node, ctx)
  local label = html.json_attr(node.attrs["data-submit-button-label"]) or "Submit"
  table.insert(out, {
    { "  ", "MarimoOutputText" },
    { " " .. tostring(label) .. " ", "MarimoWidgetButton" },
    { "  (form — submit via browser)", "Comment" },
  })
  return out
end

-- mo.ui.array / mo.ui.dict: show the current values compactly. The nested
-- <marimo-json-output> children carry escaped HTML previews of each element
-- — noise in a terminal, so we don't recurse.
local function render_dict(node, _ctx)
  local value = html.parse_initial_value(node.attrs["data-initial-value"] or "")
  local repr
  if type(value) == "table" then
    local parts = {}
    -- Marimo keys arrays "0","1",… — sort for stable display.
    local keys = vim.tbl_keys(value)
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      table.insert(parts, tostring(k) .. ": " .. vim.inspect(value[k]))
    end
    repr = "{ " .. table.concat(parts, ", ") .. " }"
  else
    repr = tostring(value)
  end
  return { {
    { "  ", "MarimoOutputText" },
    { "[array] ", "MarimoWidgetLabel" },
    { repr, "MarimoWidgetValue" },
  } }
end

-- <marimo-table> / plain <table>: scoped dataframe extraction. Only this
-- node's subtree is serialized, so a table nested inside tabs no longer
-- swallows the surrounding layout.
local function render_table(node, _ctx)
  local df = dataframe.extract_from_html(html.serialize(node))
  if df then return dataframe.render_inline(df) end
  return { { { "  [table]", "MarimoOutputText" } } }
end

local function render_img(node, ctx)
  local src = node.attrs.src or ""
  local mime, b64 = image.extract_data_uri(src)
  if mime and b64 then
    ctx.image_drawn = true
    return image.render_base64(ctx.bufnr, ctx.row or 0, mime, b64, ctx.cell_id)
  end
  if src:find("@file", 1, true) and ctx.filepath then
    ctx.image_drawn = true
    local filepath = ctx.filepath
    local server = require("neo-marimo.server")
    return image.render_url(ctx.bufnr, ctx.row or 0, src, ctx.cell_id,
      function(dest) return server.fetch_virtual_file(filepath, src, dest) end)
  end
  return { { { "  [image — install image.nvim or open in browser]", "Comment" } } }
end

local function render_svg(node, ctx)
  ctx.image_drawn = true
  return image.render_at(ctx.bufnr, ctx.row or 0,
    "image/svg+xml", html.serialize(node), ctx.cell_id)
end

-- ── dispatch ──────────────────────────────────────────────────────────────

render_node = function(node, ctx)
  if html.is_text(node) then
    local text = html.decode_entities(node.text)
    if text:match("^%s*$") then return {} end
    return render_stripped(node.text)
  end
  if not html.is_element(node) then return {} end

  local tag = node.tag

  if tag == "#root" then
    return render_children(node, ctx)
  end

  if tag == "marimo-ui-element" then
    -- Scope the wrapper's object-id over its children, restoring the outer
    -- scope afterwards (wrappers nest: form ⊃ ui-element ⊃ text).
    local prev = ctx.object_id
    ctx.object_id = node.attrs["object-id"] or prev
    local out = render_children(node, ctx)
    ctx.object_id = prev
    return out
  end

  if tag:sub(1, 7) == "marimo-" then
    local kind = tag:sub(8)

    if kind == "tabs" then return render_tabs(node, ctx) end
    if kind == "accordion" then return render_accordion(node, ctx) end
    if kind == "callout-output" then return render_callout(node, ctx) end
    if kind == "form" then return render_form(node, ctx) end
    if kind == "dict" then return render_dict(node, ctx) end
    if kind == "table" then return render_table(node, ctx) end

    if WIDGET_TAGS[kind] then
      ctx.skip_cap = true
      local w = widget_from_node(node, ctx)
      if ctx.bufnr and ctx.cell_id then
        widgets.register_widget(ctx.bufnr, ctx.cell_id, w)
      end
      return widgets.render_widget(w)
    end

    if PLACEHOLDER_TAGS[kind] then
      return { placeholder_line(PLACEHOLDER_TAGS[kind]) }
    end

    -- Unknown marimo element (new widget type, anywidget, …): show a
    -- generic widget line, register it if it carries a value, and recurse —
    -- nested ui-elements inside an unknown container still render.
    ctx.skip_cap = true
    local w = widget_from_node(node, ctx)
    if ctx.bufnr and ctx.cell_id and w.object_id then
      widgets.register_widget(ctx.bufnr, ctx.cell_id, w)
    end
    local out = widgets.render_widget(w)
    append_all(out, render_children(node, ctx))
    return out
  end

  local flex = is_flex(node)
  if flex == "column" then return render_vstack(node, ctx) end
  if flex == "row" then return render_hstack(node, ctx) end

  if tag == "table" then return render_table(node, ctx) end
  if tag == "img" then return render_img(node, ctx) end
  if tag == "svg" then return render_svg(node, ctx) end

  -- Generic container. A subtree with no structural elements is prose:
  -- markdown-looking prose (mo.md wrappers, headings, paragraphs) gets the
  -- styled markdown renderer, the rest renders as one flowing stripped
  -- string. Anything holding structural elements recurses per child.
  if is_plain(node) then
    local fragment = html.serialize(node)
    if markdown.looks_like_marimo_md_html(fragment) then
      return markdown.render(fragment)
    end
    return render_stripped(fragment)
  end
  return render_children(node, ctx)
end

-- ── entry point ───────────────────────────────────────────────────────────

-- Render an HTML payload. `ctx` is output.lua's per-cell render context;
-- this function reads bufnr/cell_id/row/filepath and writes image_drawn /
-- skip_cap back into it.
function M.render(data, ctx)
  local root, err = html.parse(data)
  if err then
    return { { { "  [output too large — open in browser (<leader>mo)]", "Comment" } } }
  end
  return render_node(root, ctx)
end

return M

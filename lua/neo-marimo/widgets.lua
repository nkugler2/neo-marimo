-- Interactive widget state + ASCII renderers for mo.ui.* outputs.
--
-- Parsing lives elsewhere since Phase 9: html.lua builds the element tree
-- and tree_render.lua walks it, calling back into this module to (a) build
-- and register widget entries per cell and (b) render each widget type as
-- virt_line chunks. This module owns:
--
--   * the per-(bufnr, cell_id) widget registry that :MarimoWidget lists
--   * persistent value overrides (so a slider the user moved doesn't snap
--     back to data-initial-value on the next re-render)
--   * the per-buffer focus model (]w / [w cycling, the ▸ marker)
--   * last-edited-widget tracking and per-notebook pins (Phase 10.4)
--   * the per-type ASCII renderers
--   * set_value — the async POST to /api/kernel/set_ui_element_value
--
-- Why interaction is keymap-driven instead of cursor-on-row dispatch:
-- virt_lines don't accept cursor focus, so a "key dispatcher keyed on
-- cursor row" can't reach a widget that lives inside a virt_line. Focus is
-- therefore plugin state (cycled with ]w / [w) and acting goes through
-- widget_picker.lua (<leader>mw and friends), which drives the same
-- set_ui_element_value endpoint the browser uses, so dependent cells re-run
-- as soon as a value changes.

local utils = require("neo-marimo.utils")

local M = {}

-- ── per-notebook widget registry ──────────────────────────────────────────
--
-- Keyed by (bufnr, cell_id) so cell re-renders blow away the old set before
-- the new one lands. Widget table fields:
--   name           - "slider", "button", "checkbox", etc.
--   object_id      - marimo's stable id for set_ui_element_value
--   value          - current value (initial-value, or the user's override)
--   options        - parsed data-* attribute map (start, stop, label, …)
--   label          - human-readable label for pickers

M._by_cell = {}

-- Persistent per-object-id value overrides. Marimo doesn't re-broadcast a
-- widget's own cell-op when its value changes, so without this map the
-- picker would update the value, POST it to the kernel, then the very next
-- cell re-render would parse the original `data-initial-value` from the
-- cached output HTML and snap the displayed thumb back to where it started.
-- Overrides persist for the lifetime of the cell; the user clears them by
-- re-running the cell or via :MarimoResetWidgets.
M._value_overrides = {}

local function registry_key(bufnr, cell_id) return bufnr .. ":" .. cell_id end

function M.clear_for_cell(bufnr, cell_id)
  M._by_cell[registry_key(bufnr, cell_id)] = nil
end

function M.list_for_cell(bufnr, cell_id)
  return M._by_cell[registry_key(bufnr, cell_id)] or {}
end

-- Add a parsed widget to the cell's registry (called by tree_render during
-- the render walk, in document order). Stamps the widget with its 1-based
-- position so focus can fall back to "same slot" when an object-id vanishes
-- across re-renders. Returns the index.
function M.register_widget(bufnr, cell_id, widget)
  local key = registry_key(bufnr, cell_id)
  M._by_cell[key] = M._by_cell[key] or {}
  table.insert(M._by_cell[key], widget)
  widget.index = #M._by_cell[key]
  return widget.index
end

-- Drop overrides for every widget previously registered against this cell.
function M.clear_overrides_for_cell(bufnr, cell_id)
  local list = M._by_cell[registry_key(bufnr, cell_id)]
  if not list then return end
  for _, w in ipairs(list) do
    if w.object_id then M._value_overrides[w.object_id] = nil end
  end
end

function M.set_override(object_id, value)
  if not object_id then return end
  M._value_overrides[object_id] = value
end

function M.get_override(object_id)
  if not object_id then return nil end
  return M._value_overrides[object_id]
end

-- Clear every value override the notebook holds. Wired to
-- :MarimoResetWidgets so the user has an explicit knob when an override has
-- gotten stale (typically: they changed the slider's code range and want
-- the new initial value back).
function M.clear_all_overrides()
  M._value_overrides = {}
end

-- ── focus model (Phase 10.1) ──────────────────────────────────────────────
--
-- One focused widget per buffer: { cell_id, object_id, index }. object_id is
-- the primary key (it survives re-renders); index is the fallback when the
-- cell's output changed shape and the id vanished.

M._focus = {}

function M.set_focus(bufnr, cell_id, object_id, index)
  M._focus[bufnr] = { cell_id = cell_id, object_id = object_id, index = index }
end

function M.get_focus(bufnr)
  return M._focus[bufnr]
end

function M.clear_focus(bufnr)
  M._focus[bufnr] = nil
end

-- Is this (widget, slot) the focused one? Called during the render walk for
-- every registered widget, so it has to be cheap.
function M.is_focused(bufnr, cell_id, widget, index)
  local f = M._focus[bufnr]
  if not f or f.cell_id ~= cell_id then return false end
  if f.object_id and widget.object_id then
    return f.object_id == widget.object_id
  end
  return f.index == index
end

-- Resolve the buffer's focus to a live registry entry (or nil if the focused
-- cell/widget no longer exists). Returns widget, cell_id.
function M.focused_widget(bufnr)
  local f = M._focus[bufnr]
  if not f then return nil end
  local list = M.list_for_cell(bufnr, f.cell_id)
  for i, w in ipairs(list) do
    if M.is_focused(bufnr, f.cell_id, w, i) then
      return w, f.cell_id
    end
  end
  return nil
end

-- Compute the next focus target for ]w / [w: the widget after/before the
-- currently focused one in notebook order (cells top-to-bottom, widgets in
-- document order within each cell), wrapping at the ends. When nothing is
-- focused — or the focus lives in a different cell than the cursor — start
-- from the cursor's cell instead, so focus never teleports somewhere
-- surprising. Returns { cell, widget, index } or nil when no cell has
-- widgets.
function M.next_focus_target(bufnr, cells, cursor_cell, dir)
  local seq = {}
  for _, c in ipairs(cells) do
    for i, w in ipairs(M.list_for_cell(bufnr, c.id)) do
      table.insert(seq, { cell = c, widget = w, index = i })
    end
  end
  if #seq == 0 then return nil end

  local f = M._focus[bufnr]
  if f and (not cursor_cell or f.cell_id == cursor_cell.id) then
    for si, e in ipairs(seq) do
      if e.cell.id == f.cell_id
          and M.is_focused(bufnr, e.cell.id, e.widget, e.index) then
        return seq[(si - 1 + dir) % #seq + 1]
      end
    end
  end

  if cursor_cell then
    if dir == 1 then
      for _, e in ipairs(seq) do
        if e.cell.index >= cursor_cell.index then return e end
      end
      return seq[1]
    end
    for si = #seq, 1, -1 do
      if seq[si].cell.index <= cursor_cell.index then return seq[si] end
    end
    return seq[#seq]
  end
  return dir == 1 and seq[1] or seq[#seq]
end

-- ── last-edited widget (Phase 10.4) ───────────────────────────────────────
--
-- Updated on every committed value change; <leader>m. re-opens the edit
-- prompt for it without hunting for the cell. Stores the nb reference (the
-- same table init.lua keeps in _attached) so the shortcut works across
-- notebook buffers.

M._last_widget = nil

function M.set_last(nb, cell_id, object_id)
  M._last_widget = { nb = nb, cell_id = cell_id, object_id = object_id }
end

function M.get_last()
  return M._last_widget
end

-- ── pinned widgets (Phase 10.4) ───────────────────────────────────────────
--
-- Per-notebook (keyed by filepath) ordered list of
-- { cell_id, object_id, label, name } so favourite widgets anywhere in the
-- notebook are one keystroke away. Matching against the live registry is by
-- object_id; entries whose widget disappeared render greyed-out in the panel
-- until unpinned. State is session-scoped — it dies with nvim.

M._pins = {}

function M.pins_for(filepath)
  return M._pins[filepath] or {}
end

local function find_pin(filepath, object_id)
  for i, p in ipairs(M._pins[filepath] or {}) do
    if p.object_id == object_id then return i end
  end
  return nil
end

function M.is_pinned(filepath, object_id)
  return find_pin(filepath, object_id) ~= nil
end

-- Toggle a pin. Returns true if the widget is now pinned, false if
-- unpinned, nil if it can't be pinned (no object-id to re-find it by).
function M.toggle_pin(filepath, cell_id, widget)
  if not widget.object_id then return nil end
  M._pins[filepath] = M._pins[filepath] or {}
  local at = find_pin(filepath, widget.object_id)
  if at then
    table.remove(M._pins[filepath], at)
    return false
  end
  table.insert(M._pins[filepath], {
    cell_id = cell_id,
    object_id = widget.object_id,
    label = widget.label,
    name = widget.name,
  })
  return true
end

function M.unpin(filepath, index)
  local pins = M._pins[filepath]
  if pins and pins[index] then table.remove(pins, index) end
end

-- ── value coercion helpers (used by renderers) ────────────────────────────

local function to_bool(s, default)
  if s == nil then return default end
  if s == true or s == "true" or s == "1" or s == "yes" then return true end
  if s == false or s == "false" or s == "0" or s == "no" then return false end
  return default
end

-- ── per-type renderers ────────────────────────────────────────────────────
--
-- Each renderer takes the parsed widget table and returns a list of
-- virt_line chunks (i.e. a list of {text, hl_group}-tuple lists).

local function render_slider(w)
  local start = w.options.start or 0
  local stop = w.options.stop or 1
  local label = w.options.label or "slider"

  -- range_slider carries a {lo, hi} table; position the thumb at the low
  -- end and display the pair.
  local value = w.value
  local display, pos_value
  if type(value) == "table" then
    display = tostring(value[1]) .. "‥" .. tostring(value[2] or value[1])
    pos_value = tonumber(value[1]) or start
  else
    pos_value = tonumber(value) or start
    display = tostring(pos_value)
  end

  local width = 24
  local denom = (stop - start)
  local pos = 0
  if denom ~= 0 then
    pos = math.floor(((pos_value - start) / denom) * (width - 1) + 0.5)
    if pos < 0 then pos = 0 end
    if pos > width - 1 then pos = width - 1 end
  end

  return { {
    { "  ", "MarimoOutputText" },
    { label .. ": ", "MarimoWidgetLabel" },
    { "[", "MarimoWidgetTrack" },
    { string.rep("━", pos), "MarimoWidgetTrack" },
    { "●", "MarimoWidgetThumb" },
    { string.rep("━", width - pos - 1), "MarimoWidgetTrack" },
    { "] ", "MarimoWidgetTrack" },
    { display, "MarimoWidgetValue" },
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
  local checked = to_bool(w.value, false)
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
    repr = table.concat(vim.tbl_map(tostring, value), ", ")
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

local function render_refresh(w)
  -- data-default-interval arrives JSON-encoded ('"1m"').
  local interval = w.options.default_interval or ""
  interval = interval:gsub('^"', ""):gsub('"$', "")
  return { {
    { "  ", "MarimoOutputText" },
    { "↻ refresh", "MarimoWidgetLabel" },
    { interval ~= "" and ("  every " .. interval) or "", "MarimoWidgetValue" },
    { "  (runs in browser)", "Comment" },
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

-- Renderer table keyed on the widget name: the suffix of `<marimo-{name}>`
-- normalised to snake_case ("text-area" → "text_area").
local RENDERERS = {
  slider       = render_slider,
  range_slider = render_slider,
  button       = render_button,
  checkbox     = render_checkbox,
  switch       = render_checkbox,
  text         = render_text,
  text_area    = render_text_area,
  dropdown     = render_dropdown,
  multiselect  = render_multiselect,
  number       = render_number,
  date         = render_date,
  datetime     = render_date,
  radio        = render_radio,
  refresh      = render_refresh,
}

-- Render one widget table into virt_line chunks. When the widget is the
-- buffer's focused one (w.focused, set during the tree_render walk), the
-- leading indent becomes a ▸ marker and the first labeled chunk flips to
-- the MarimoWidgetFocused highlight — same display width, so columns in
-- hstacks and vstack alignment don't shift.
function M.render_widget(w)
  local renderer = RENDERERS[w.name] or render_unknown
  local lines = renderer(w)
  if w.focused and lines[1] then
    local first = lines[1]
    if first[1] and first[1][1] == "  " then
      first[1] = { "▸ ", "MarimoWidgetFocused" }
    else
      table.insert(first, 1, { "▸ ", "MarimoWidgetFocused" })
    end
    if first[2] then
      first[2] = { first[2][1], "MarimoWidgetFocused" }
    end
  end
  return lines
end

-- Public extension point: register (or replace) the renderer for a widget
-- name. `fn(w) -> virt_lines` where w is the widget table described at the
-- top of this file.
function M.register_renderer(name, fn)
  RENDERERS[name] = fn
end

-- ── kernel interaction ────────────────────────────────────────────────────

-- POST a new value for a widget to /api/kernel/set_ui_element_value.
-- Asynchronous: `on_done(ok)` is called on the main loop once the request
-- finishes (HTTP 200 → true, anything else → false after a [neo-marimo]
-- warning). The old synchronous form froze the UI for up to 10 s on a slow
-- kernel — fatal for slider nudging, where keypresses arrive faster than
-- round-trips. After a successful POST, marimo recomputes any cells that
-- depend on the widget and broadcasts cell-op for each — the widget's own
-- cell does NOT re-broadcast though, which is why callers also stash an
-- override in M._value_overrides so the next render of *this* cell shows
-- the new value.
function M.set_value(filepath, object_id, value, on_done)
  on_done = on_done or function() end
  if not object_id or object_id == "" then
    utils.warn("Widget has no object-id; can't update its value.")
    on_done(false)
    return
  end

  local server = require("neo-marimo.server")
  local srv = server._servers and server._servers[filepath]
  if not srv then
    utils.warn("No server running for this notebook — cannot set widget value.")
    on_done(false)
    return
  end

  -- Field names use camelCase. Marimo's other kernel endpoints
  -- (/api/kernel/run, /api/kernel/instantiate) take `cellIds`, `objectIds`,
  -- `autoRun`, etc. — same pattern here.
  local body = vim.json.encode({
    objectIds = { object_id },
    values    = { value },
  })
  local args = {
    "curl", "-s", "--max-time", "10",
    "-w", "\n%{http_code}",
    "-X", "POST",
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

  vim.system(args, { text = true }, function(r)
    vim.schedule(function()
      if r.code ~= 0 then
        utils.warn("set_ui_element_value: curl exit " .. tostring(r.code))
        on_done(false)
        return
      end
      local out_body, status = (r.stdout or ""):match("^(.*)\n(%d+)%s*$")
      if not status then status = "?"; out_body = r.stdout end
      if status ~= "200" then
        utils.warn("set_ui_element_value → HTTP " .. status .. ": " ..
          (out_body or ""):sub(1, 200))
        on_done(false)
        return
      end
      on_done(true)
    end)
  end)
end

-- ── picker labels ─────────────────────────────────────────────────────────

-- Build a human-readable list-row label for use in pickers. Long string
-- values (multiselect arrays, text_area bodies) get truncated to ~30 chars
-- so the picker row stays one line.
local function short(v, n)
  local s
  if type(v) == "table" then
    s = table.concat(vim.tbl_map(tostring, v), ",")
  else
    s = tostring(v)
  end
  s = s:gsub("[\n\r]", " ")
  n = n or 30
  if #s > n then s = s:sub(1, n - 1) .. "…" end
  return s
end

function M.describe(w)
  if w.name == "slider" or w.name == "range_slider" then
    return string.format("slider · %s = %s (%s‥%s)",
      w.label, short(w.value, 20),
      tostring(w.options.start), tostring(w.options.stop))
  elseif w.name == "checkbox" or w.name == "switch" then
    return string.format("%s · %s = %s", w.name, w.label, short(w.value, 8))
  elseif w.name == "button" then
    return string.format("button · %s", w.label)
  else
    return string.format("%s · %s = %s", w.name, w.label, short(w.value))
  end
end

return M

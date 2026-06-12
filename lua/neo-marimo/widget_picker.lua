-- Phase 10 — widget interaction UX.
--
-- Entry points (wired in keymaps.lua / plugin commands):
--   M.smart(nb, cell)   <leader>mw — act on the focused widget if one is
--                       focused in this cell, act directly when the cell has
--                       exactly one widget, otherwise open the picker
--   M.open(nb, cell)    <leader>mW — ordered, tab-aware picker: digits 1-9
--                       act immediately, <Tab>/<S-Tab> cycle tab groups
--   M.act_last()        <leader>m. — re-open the edit prompt for the
--                       last-committed widget, wherever it lives
--   M.open_pins(nb)     <leader>mp — panel of pinned widgets (stale pins
--                       grey out; x unpins)
--   M.nudge(nb,cell,d)  + / - — step the focused slider/number without a
--                       prompt; POSTs are debounced so held keys coalesce
--
-- Every path funnels into interact() → commit(), which POSTs the new value
-- via widgets.set_value (async), after which marimo's reactive dispatch
-- re-runs dependent cells and the new state flows back into our cell-op
-- handler.

local widgets = require("neo-marimo.widgets")
local utils = require("neo-marimo.utils")

local M = {}

local ns_picker = vim.api.nvim_create_namespace("neo_marimo_widget_picker")

-- ── per-type interactions ────────────────────────────────────────────────

local function prompt_number(label, current, on_set)
  vim.ui.input({
    prompt = label .. " = ",
    default = tostring(current or ""),
  }, function(input)
    if input == nil then return end
    local n = tonumber(input)
    if not n then
      vim.notify("[neo-marimo] not a number: " .. input, vim.log.levels.WARN)
      return
    end
    on_set(n)
  end)
end

local function prompt_text(label, current, on_set)
  vim.ui.input({
    prompt = label .. " = ",
    default = tostring(current or ""),
  }, function(input)
    if input == nil then return end
    on_set(input)
  end)
end

local function prompt_select(label, options, on_set)
  vim.ui.select(options, { prompt = label .. ":" }, function(choice)
    if choice == nil then return end
    on_set(choice)
  end)
end

-- After a value change, both the override registry and the cell need to be
-- poked so the user sees the new value immediately. The cell output text
-- doesn't change, so the next render would otherwise re-parse the original
-- data-initial-value and snap the thumb back.
--
-- The POST is async (widgets.set_value): the cell optimistically shows ⟳
-- while the request is in flight. handle_cell_op clears _optimistic_status
-- the moment a real kernel status lands; if none has arrived by the time
-- the callback fires (e.g. the WS is released to the browser, so no echo is
-- coming), the status rolls back so the spinner can't get stuck.
local function commit(nb, cell, w, value)
  widgets.set_override(w.object_id, value)
  w.value = value
  widgets.set_last(nb, cell.id, w.object_id)

  local output = require("neo-marimo.output")
  local prev_status = cell.status
  cell.status = "running"
  cell._optimistic_status = true
  -- filepath matters: without it a re-render drops any virtual-file
  -- image this cell's output also contains. The explicit redraws matter
  -- too: extmark changes made from timer/async contexts otherwise sit
  -- unpainted until the next UI event (observed as "value updates only
  -- when I move the cursor").
  output.render(nb.bufnr, cell, nb.filepath)
  vim.cmd("redraw")

  widgets.set_value(nb.filepath, w.object_id, value, function(_ok)
    if cell._optimistic_status then
      cell.status = prev_status
      cell._optimistic_status = nil
      if vim.api.nvim_buf_is_valid(nb.bufnr) then
        output.render(nb.bufnr, cell, nb.filepath)
        vim.cmd("redraw")
      end
    end
  end)
end

local function interact(nb, cell, w)
  if not w.object_id then
    vim.notify("[neo-marimo] widget has no object-id; cannot update",
      vim.log.levels.WARN)
    return
  end

  if w.name == "slider" or w.name == "number" or w.name == "range_slider" then
    prompt_number(w.label, w.value, function(v)
      commit(nb, cell, w, v)
    end)

  elseif w.name == "checkbox" or w.name == "switch" then
    local nv = not (w.value == true or w.value == "true" or w.value == 1)
    commit(nb, cell, w, nv)
    vim.notify("[neo-marimo] " .. w.label .. " = " .. tostring(nv),
      vim.log.levels.INFO)

  elseif w.name == "button" then
    -- Marimo button "press" is an integer-incrementing counter on the
    -- kernel side. Send `current + 1`; the kernel re-runs anything that
    -- read button.value.
    local cur = tonumber(w.value) or 0
    commit(nb, cell, w, cur + 1)
    vim.notify("[neo-marimo] pressed " .. w.label, vim.log.levels.INFO)

  elseif w.name == "text" or w.name == "text_area" then
    prompt_text(w.label, w.value, function(v) commit(nb, cell, w, v) end)

  elseif w.name == "dropdown" then
    -- Marimo serializes the option list in data-options as JSON; fall back
    -- to "type a value" if we don't see one.
    local opts_raw = w.options.options
    if opts_raw then
      local ok, opts = pcall(vim.json.decode, opts_raw)
      if ok and type(opts) == "table" then
        prompt_select(w.label, opts, function(v) commit(nb, cell, w, v) end)
        return
      end
    end
    prompt_text(w.label, w.value, function(v) commit(nb, cell, w, v) end)

  elseif w.name == "multiselect" then
    prompt_text(w.label .. " (comma-separated)",
      type(w.value) == "table" and table.concat(w.value, ", ") or "",
      function(input)
        local list = {}
        for part in (input .. ","):gmatch("([^,]*),") do
          local trimmed = part:match("^%s*(.-)%s*$")
          if trimmed ~= "" then table.insert(list, trimmed) end
        end
        commit(nb, cell, w, list)
      end)

  else
    prompt_text(w.label, w.value, function(v) commit(nb, cell, w, v) end)
  end
end

-- ── nudging (slider / number / range_slider) ─────────────────────────────

local NUDGEABLE = { slider = true, range_slider = true, number = true }

-- Pure value math: the next value for a nudge in direction `dir` (±1), or
-- nil when the widget type can't be nudged. Sliders constructed with an
-- explicit steps list (data-steps='[…]') walk that list; everything else
-- moves by data-step (default 1) and clamps to [start, stop] when bounds
-- exist (mo.ui.number without min/max has none).
function M.nudge_value(w, dir)
  if not NUDGEABLE[w.name] then return nil end

  local lo_bound = tonumber(w.options.start)
  local hi_bound = tonumber(w.options.stop)
  local function clamp(v)
    if lo_bound and v < lo_bound then v = lo_bound end
    if hi_bound and v > hi_bound then v = hi_bound end
    return v
  end

  -- Explicit steps list: snap to the nearest entry, then move one slot.
  local steps
  if w.options.steps then
    local ok, decoded = pcall(vim.json.decode, w.options.steps)
    if ok and type(decoded) == "table" and #decoded > 0 then steps = decoded end
  end
  local function next_step(cur)
    local best, best_d = 1, math.huge
    for i, s in ipairs(steps) do
      local d = math.abs((tonumber(s) or 0) - cur)
      if d < best_d then best, best_d = i, d end
    end
    local i = math.max(1, math.min(#steps, best + dir))
    return tonumber(steps[i])
  end

  local step = tonumber(w.options.step) or 1
  local function move(cur)
    if steps then return next_step(cur) end
    return clamp(cur + dir * step)
  end

  if type(w.value) == "table" then
    -- range_slider: shift the whole window, clamping each end.
    local lo = tonumber(w.value[1]) or lo_bound or 0
    local hi = tonumber(w.value[2] or w.value[1]) or lo
    return { move(lo), move(hi) }
  end
  local cur = tonumber(w.value)
  if cur == nil then cur = lo_bound or 0 end
  return move(cur)
end

-- Held +/- emits keypresses faster than kernel round-trips, so the override
-- and re-render happen per press (instant thumb movement) while the POST is
-- debounced: only the final value after ~150ms of quiet goes to the kernel.
local _nudge_pending = nil
local _post_nudge = utils.debounce(function()
  local p = _nudge_pending
  _nudge_pending = nil
  if p then commit(p.nb, p.cell, p.w, p.value) end
end, 150)

-- Nudge the focused widget, provided it lives in the cell under the cursor
-- and is nudgeable. Returns true when handled — the keymap replays the
-- native key otherwise, so <C-a>/<C-x> still increment numbers in code.
function M.nudge(nb, cell, dir)
  local fw, fcell_id = widgets.focused_widget(nb.bufnr)
  if not (fw and fcell_id == cell.id and NUDGEABLE[fw.name] and fw.object_id) then
    return false
  end

  local value = M.nudge_value(fw, dir)
  if value == nil then return false end

  widgets.set_override(fw.object_id, value)
  fw.value = value
  require("neo-marimo.output").render(nb.bufnr, cell, nb.filepath)
  vim.cmd("redraw")

  _nudge_pending = { nb = nb, cell = cell, w = fw, value = value }
  _post_nudge()
  return true
end

-- ── picker plumbing ──────────────────────────────────────────────────────

-- Group a cell's widget list into picker pages by the tab each widget lives
-- in: widgets outside any tab share one unlabeled group, every tabs body is
-- its own group (keyed on the w.tab table tree_render stamps — one shared
-- instance per body), all in document order. Exposed for tests.
function M._group_by_tab(list)
  local groups, by_key = {}, {}
  for _, w in ipairs(list) do
    local key = w.tab or "main"
    local g = by_key[key]
    if not g then
      g = { label = w.tab and w.tab.label or nil, items = {} }
      by_key[key] = g
      table.insert(groups, g)
    end
    table.insert(g.items, w)
  end
  return groups
end

-- Shared floating-window scaffolding for the widget picker and the pin
-- panel. `build()` returns { lines = {...}, stale = {row→true} }; rebinding
-- happens once, rebuilds just swap the buffer text.
local function open_float(title, build, binds)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "marimo-widget-picker", { buf = buf })

  local win

  local function refresh()
    local view = build()
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, view.lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_buf_clear_namespace(buf, ns_picker, 0, -1)
    for row in pairs(view.stale or {}) do
      vim.api.nvim_buf_set_extmark(buf, ns_picker, row - 1, 0, {
        end_row = row, hl_group = "Comment", hl_eol = true,
      })
    end

    local width = 40
    for _, l in ipairs(view.lines) do
      local w = vim.fn.strdisplaywidth(l)
      if w + 2 > width then width = w + 2 end
    end
    local height = math.min(#view.lines + 1, 14)

    if not win then
      win = vim.api.nvim_open_win(buf, true, {
        relative = "cursor",
        width = width, height = height,
        row = 1, col = 0,
        style = "minimal", border = "rounded",
        title = title, title_pos = "center",
      })
      vim.api.nvim_set_option_value("cursorline", true, { win = win })
    else
      vim.api.nvim_win_set_config(win, { width = width, height = height })
    end
    vim.api.nvim_win_set_cursor(win, { 1, 1 })
  end

  local function close()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  refresh()

  local function bind(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, {
      buffer = buf, silent = true, noremap = true, desc = desc,
    })
  end
  bind("q", close, "Close")
  bind("<Esc>", close, "Close")
  binds(bind, close, refresh)
end

-- ── widget picker (ordered + tab-aware) ──────────────────────────────────

function M.open(nb, cell)
  local list = widgets.list_for_cell(nb.bufnr, cell.id)
  if #list == 0 then
    vim.notify("[neo-marimo] No widgets in this cell's output.",
      vim.log.levels.INFO)
    return
  end

  local groups = M._group_by_tab(list)
  local gi = 1

  local function build()
    local g = groups[gi]
    local lines = {}
    for i, w in ipairs(g.items) do
      table.insert(lines, string.format(" %d. %s", i, widgets.describe(w)))
    end
    table.insert(lines, "")
    if #groups > 1 then
      table.insert(lines, string.format(" Tab: %s [%d/%d] · <Tab>/<S-Tab> switch",
        g.label or "main", gi, #groups))
    end
    table.insert(lines, " 1-9/<CR> act · q/<Esc> close")
    return { lines = lines }
  end

  local cell_label = cell.name ~= "_" and cell.name or ("cell " .. cell.index)
  open_float(" widgets · " .. cell_label .. " ", build, function(bind, close, refresh)
    local function act(w)
      if not w then return end
      close()
      interact(nb, cell, w)
    end

    for d = 1, 9 do
      bind(tostring(d), function() act(groups[gi].items[d]) end,
        "Act on widget " .. d)
    end
    bind("<CR>", function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      act(groups[gi].items[row])
    end, "Act on selected widget")

    if #groups > 1 then
      bind("<Tab>", function()
        gi = gi % #groups + 1
        refresh()
      end, "Next tab")
      bind("<S-Tab>", function()
        gi = (gi - 2) % #groups + 1
        refresh()
      end, "Previous tab")
    end
  end)
end

-- Smart act for <leader>mw. A focused widget (set via ]w / [w) in this cell
-- wins; a single-widget cell skips the menu entirely; only genuinely
-- ambiguous cells get the picker.
function M.smart(nb, cell)
  local list = widgets.list_for_cell(nb.bufnr, cell.id)
  if #list == 0 then
    vim.notify("[neo-marimo] No widgets in this cell's output.",
      vim.log.levels.INFO)
    return
  end
  local fw, fcell_id = widgets.focused_widget(nb.bufnr)
  if fw and fcell_id == cell.id then
    interact(nb, cell, fw)
    return
  end
  if #list == 1 then
    interact(nb, cell, list[1])
    return
  end
  M.open(nb, cell)
end

-- ── last-edited widget ───────────────────────────────────────────────────

-- Re-open the edit prompt for the most recently committed widget, jumping
-- buffer/cursor to its cell first. One keystroke per iteration when
-- tweaking a value and watching downstream cells change.
function M.act_last()
  local last = widgets.get_last()
  if not last then
    vim.notify("[neo-marimo] No widget edited yet this session.",
      vim.log.levels.INFO)
    return
  end
  local nb = last.nb
  if not (nb.bufnr and vim.api.nvim_buf_is_valid(nb.bufnr)) then
    vim.notify("[neo-marimo] Last-edited widget's notebook is gone.",
      vim.log.levels.WARN)
    return
  end
  local cell = nb.cell_by_id[last.cell_id]
  local w
  if cell then
    for _, cand in ipairs(widgets.list_for_cell(nb.bufnr, cell.id)) do
      if cand.object_id == last.object_id then w = cand; break end
    end
  end
  if not w then
    vim.notify("[neo-marimo] Last-edited widget is no longer in any cell output.",
      vim.log.levels.WARN)
    return
  end

  if vim.api.nvim_get_current_buf() ~= nb.bufnr then
    vim.api.nvim_win_set_buf(0, nb.bufnr)
  end
  local row = math.min(cell.start_row + 1, vim.api.nvim_buf_line_count(nb.bufnr))
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  interact(nb, cell, w)
end

-- ── pinned-widget panel ──────────────────────────────────────────────────

-- Resolve each pin against the live registry: returns rows of
-- { pin, cell, widget } where widget == nil marks a stale pin (cell deleted
-- or its output no longer contains the object-id).
local function resolve_pins(nb)
  local rows = {}
  for _, p in ipairs(widgets.pins_for(nb.filepath)) do
    local cell = nb.cell_by_id[p.cell_id]
    local w
    if cell then
      for _, cand in ipairs(widgets.list_for_cell(nb.bufnr, cell.id)) do
        if cand.object_id == p.object_id then w = cand; break end
      end
    end
    table.insert(rows, { pin = p, cell = cell, widget = w })
  end
  return rows
end

function M.open_pins(nb)
  if #widgets.pins_for(nb.filepath) == 0 then
    vim.notify("[neo-marimo] No pinned widgets — pin one with the pin-toggle keymap.",
      vim.log.levels.INFO)
    return
  end

  local rows

  local function build()
    rows = resolve_pins(nb)
    local lines, stale = {}, {}
    for i, r in ipairs(rows) do
      if r.widget then
        table.insert(lines, string.format(" %d. %s   [cell %s]",
          i, widgets.describe(r.widget), tostring(r.cell.index)))
      else
        table.insert(lines, string.format(" %d. %s · %s — gone (x unpins)",
          i, r.pin.name, r.pin.label))
        stale[#lines] = true
      end
    end
    table.insert(lines, "")
    table.insert(lines, " 1-9/<CR> act · x unpin · q/<Esc> close")
    return { lines = lines, stale = stale }
  end

  open_float(" pinned widgets ", build, function(bind, close, refresh)
    -- Acting on a pin edits the widget in place — the cursor stays where
    -- it is, so pinned widgets anywhere in the notebook are reachable
    -- without losing your spot.
    local function act(r)
      if not r then return end
      if not r.widget then
        vim.notify("[neo-marimo] That widget is gone — press x to unpin it.",
          vim.log.levels.WARN)
        return
      end
      close()
      interact(nb, r.cell, r.widget)
    end

    for d = 1, 9 do
      bind(tostring(d), function() act(rows[d]) end, "Act on pin " .. d)
    end
    bind("<CR>", function()
      act(rows[vim.api.nvim_win_get_cursor(0)[1]])
    end, "Act on selected pin")
    bind("x", function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if rows[row] then
        widgets.unpin(nb.filepath, row)
        if #widgets.pins_for(nb.filepath) == 0 then
          close()
          return
        end
        refresh()
      end
    end, "Unpin selected widget")
  end)
end

return M

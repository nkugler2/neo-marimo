-- Phase 8.3 — widget interaction picker.
--
-- Opens a floating window listing every UI widget marimo emitted in the
-- cell's last output. <CR> on a row drives the right interaction for that
-- widget type (slider → prompt for value, button → press, etc.) and POSTs
-- the new value via widgets.set_value, after which marimo's reactive
-- dispatch re-runs dependent cells and the new state flows back into our
-- cell-op handler.

local widgets = require("neo-marimo.widgets")

local M = {}

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

local function interact(nb, w)
  if not w.object_id then
    vim.notify("[neo-marimo] widget has no object-id; cannot update",
      vim.log.levels.WARN)
    return
  end

  if w.name == "slider" or w.name == "number" then
    prompt_number(w.label, w.value, function(v)
      w.value = v
      widgets.set_value(nb.filepath, w.object_id, v)
    end)

  elseif w.name == "checkbox" or w.name == "switch" then
    local nv = not (w.value == true or w.value == "true" or w.value == 1)
    w.value = nv
    widgets.set_value(nb.filepath, w.object_id, nv)
    vim.notify("[neo-marimo] " .. w.label .. " = " .. tostring(nv),
      vim.log.levels.INFO)

  elseif w.name == "button" then
    widgets.set_value(nb.filepath, w.object_id, (w.value or 0) + 1)
    vim.notify("[neo-marimo] pressed " .. w.label, vim.log.levels.INFO)

  elseif w.name == "text" or w.name == "text_area" then
    prompt_text(w.label, w.value, function(v)
      w.value = v
      widgets.set_value(nb.filepath, w.object_id, v)
    end)

  elseif w.name == "dropdown" then
    -- Marimo serializes the option list in data-options as JSON; fall back
    -- to "type a value" if we don't see one.
    local opts_raw = w.options.options
    if opts_raw then
      local ok, opts = pcall(vim.json.decode, opts_raw)
      if ok and type(opts) == "table" then
        prompt_select(w.label, opts, function(v)
          w.value = v
          widgets.set_value(nb.filepath, w.object_id, v)
        end)
        return
      end
    end
    prompt_text(w.label, w.value, function(v)
      w.value = v
      widgets.set_value(nb.filepath, w.object_id, v)
    end)

  elseif w.name == "multiselect" then
    prompt_text(w.label .. " (comma-separated)",
      type(w.value) == "table" and table.concat(w.value, ", ") or "",
      function(input)
        local list = {}
        for part in (input .. ","):gmatch("([^,]*),") do
          local trimmed = part:match("^%s*(.-)%s*$")
          if trimmed ~= "" then table.insert(list, trimmed) end
        end
        w.value = list
        widgets.set_value(nb.filepath, w.object_id, list)
      end)

  else
    prompt_text(w.label, w.value, function(v)
      widgets.set_value(nb.filepath, w.object_id, v)
    end)
  end
end

-- ── picker UI ────────────────────────────────────────────────────────────

function M.open(nb, cell)
  local list = widgets.list_for_cell(nb.bufnr, cell.id)
  if #list == 0 then
    vim.notify("[neo-marimo] No widgets in this cell's output.",
      vim.log.levels.INFO)
    return
  end

  local lines = {}
  for i, w in ipairs(list) do
    table.insert(lines, string.format(" %d. %s", i, widgets.describe(w)))
  end
  table.insert(lines, "")
  table.insert(lines, " <CR> interact · q/<Esc> close")

  local width = 0
  for _, l in ipairs(lines) do
    if #l > width then width = #l end
  end
  width = math.max(40, width + 2)
  local height = math.min(#lines + 1, 12)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "marimo-widget-picker", { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    width = width,
    height = height,
    row = 1,
    col = 0,
    style = "minimal",
    border = "rounded",
    title = " widgets · " .. (cell.name ~= "_" and cell.name or "cell " .. cell.index) .. " ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_win_set_cursor(win, { 1, 1 })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function bind(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, {
      buffer = buf, silent = true, noremap = true, desc = desc,
    })
  end

  bind("q", close, "Close widget picker")
  bind("<Esc>", close, "Close widget picker")
  bind("<CR>", function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local w = list[row]
    if not w then return end
    close()
    interact(nb, w)
  end, "Interact with selected widget")
end

return M

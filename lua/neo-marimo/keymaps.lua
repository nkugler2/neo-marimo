local config = require("neo-marimo.config")
local notebook = require("neo-marimo.notebook")
local buffer = require("neo-marimo.buffer")
local server = require("neo-marimo.server")
local output = require("neo-marimo.output")
local actions = require("neo-marimo.actions")
local lsp = require("neo-marimo.lsp")
local dataframe = require("neo-marimo.dataframe")
local widgets = require("neo-marimo.widgets")

local M = {}

-- Move cursor to the start of a cell
local function jump_to_cell(cell)
  if cell then
    -- +1 because nvim_win_set_cursor is 1-indexed
    local row = cell.start_row + 1
    local line_count = vim.api.nvim_buf_line_count(0)
    if row > line_count then row = line_count end
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end
end

-- Get the notebook state from a buffer (stored as buffer variable)
local function get_nb(bufnr)
  return vim.b[bufnr]._marimo_notebook
end

-- Set notebook state on buffer
local function set_nb(bufnr, nb)
  vim.b[bufnr]._marimo_notebook = nb
end

function M.setup(bufnr, nb)
  local km = config.options.keymaps
  if not km then return end

  local opts = { buffer = bufnr, silent = true, noremap = true }

  -- Helper to make a desc opts table
  local function o(desc)
    return vim.tbl_extend("force", opts, { desc = desc })
  end

  -- Next cell
  if km.next_cell then
    vim.keymap.set("n", km.next_cell, function()
      if nb._flush_pending then nb._flush_pending() end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if cell and cell.index < #nb.cells then
        jump_to_cell(nb.cells[cell.index + 1])
      end
    end, o("Marimo: next cell"))
  end

  -- Previous cell
  if km.prev_cell then
    vim.keymap.set("n", km.prev_cell, function()
      if nb._flush_pending then nb._flush_pending() end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if cell and cell.index > 1 then
        jump_to_cell(nb.cells[cell.index - 1])
      end
    end, o("Marimo: previous cell"))
  end

  -- New cell below
  if km.new_cell_below then
    vim.keymap.set("n", km.new_cell_below, function()
      actions.new_cell_below(bufnr, nb)
    end, o("Marimo: new cell below"))
  end

  -- New cell above
  if km.new_cell_above then
    vim.keymap.set("n", km.new_cell_above, function()
      actions.new_cell_above(bufnr, nb)
    end, o("Marimo: new cell above"))
  end

  -- Delete cell
  if km.delete_cell then
    vim.keymap.set("n", km.delete_cell, function()
      actions.delete_cell_at_cursor(bufnr, nb)
    end, o("Marimo: delete cell"))
  end

  -- Move cell down
  if km.move_cell_down then
    vim.keymap.set("n", km.move_cell_down, function()
      actions.move_cell_down_at_cursor(bufnr, nb)
    end, o("Marimo: move cell down"))
  end

  -- Move cell up
  if km.move_cell_up then
    vim.keymap.set("n", km.move_cell_up, function()
      actions.move_cell_up_at_cursor(bufnr, nb)
    end, o("Marimo: move cell up"))
  end

  -- Open in browser (starts server if needed)
  if km.open_in_browser then
    vim.keymap.set("n", km.open_in_browser, function()
      actions.open_in_browser(nb)
    end, o("Marimo: start server and open in browser"))
  end

  -- Stop server
  if km.stop_server then
    vim.keymap.set("n", km.stop_server, function()
      server.stop(nb.filepath)
      output.clear_all(bufnr)
    end, o("Marimo: stop server"))
  end

  -- Run cell under cursor
  if km.run_cell then
    vim.keymap.set("n", km.run_cell, function()
      actions.run_cell_at_cursor(bufnr, nb)
    end, o("Marimo: run cell"))
  end

  -- Run all cells
  if km.run_all then
    vim.keymap.set("n", km.run_all, function()
      actions.run_all_cells(bufnr, nb)
    end, o("Marimo: run all cells"))
  end

  -- Toggle output visibility
  if km.toggle_output then
    vim.keymap.set("n", km.toggle_output, function()
      if nb._flush_pending then nb._flush_pending() end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if not cell then return end

      if cell._output_hidden then
        cell._output_hidden = false
        output.render(bufnr, cell, nb.filepath)
      else
        cell._output_hidden = true
        vim.api.nvim_buf_clear_namespace(bufnr, require("neo-marimo.highlights").ns_output,
          cell.start_row, cell.end_row + 1)
      end
    end, o("Marimo: toggle cell output"))
  end

  -- Toggle between notebook view and underlying .py
  if km.toggle_view then
    vim.keymap.set("n", km.toggle_view, function()
      require("neo-marimo").toggle(bufnr)
    end, o("Marimo: toggle notebook view"))
  end

  -- Reclaim the WebSocket from the browser. After :MarimoEdit /
  -- <leader>mo we release the WS so the browser can connect; this
  -- takes it back so nvim resumes receiving cell-op messages.
  if km.reclaim_ws then
    vim.keymap.set("n", km.reclaim_ws, function()
      server.reclaim_ws(nb.filepath)
    end, o("Marimo: reclaim WebSocket from browser"))
  end

  -- LSP: hover, signature help, goto-definition, completion.
  -- Routed through a hidden shadow buffer (see lua/neo-marimo/lsp.lua).
  -- The default keymaps mirror nvim's built-in LSP defaults so muscle
  -- memory carries over from regular Python buffers.
  if km.hover ~= false then
    vim.keymap.set("n", km.hover or "K", function()
      lsp.hover()
    end, o("Marimo: hover (LSP)"))
  end

  if km.signature_help ~= false then
    vim.keymap.set("i", km.signature_help or "<C-k>", function()
      lsp.signature()
    end, o("Marimo: signature help (LSP)"))
  end

  if km.goto_definition ~= false then
    vim.keymap.set("n", km.goto_definition or "gd", function()
      lsp.goto_definition()
    end, o("Marimo: goto definition (LSP)"))
  end

  -- Wire <C-x><C-o> through our completefunc. The user's completion
  -- plugin (nvim-cmp, blink.cmp, coq, etc.) can also drive completion
  -- by calling neo_marimo_omnifunc(findstart, base) — most users will
  -- hit <C-x><C-o> directly, so setting omnifunc on the notebook
  -- buffer covers the default UX.
  if km.completion ~= false then
    vim.api.nvim_set_option_value(
      "omnifunc", "v:lua.neo_marimo_omnifunc",
      { buf = bufnr }
    )
  end

  -- Smart paste: when the cursor sits on the only row of a cell and that
  -- row is empty (typical right after `<leader>mn`), vanilla `p` would
  -- put the yanked content *below* the empty row, leaving a stray blank
  -- line above the paste inside the cell. Both `Vp` and a plain
  -- nvim_buf_set_lines substitution at the cell's row drag this cell's
  -- start anchor onto the next cell's (the single-line substitution
  -- moves both right-gravity marks past the new content), so the paste
  -- ends up swallowed by the *previous* cell. Do the substitution
  -- ourselves and immediately re-place this cell's anchor at the
  -- original row so it claims the pasted lines.
  local function paste_in_empty_cell(default_key)
    return function()
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if cell and cell.start_row == cell.end_row then
        local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
        if line == "" then
          local reg = vim.fn.getreg('"')
          local regtype = vim.fn.getregtype('"')
          -- Only linewise yanks (yy, dd, <leader>md trash) need the
          -- empty-row replacement dance. Charwise / blockwise paste
          -- inserts bytes at the cursor and the empty row absorbs them
          -- without leaving a stray blank.
          if reg ~= "" and regtype:sub(1, 1) == "V" then
            local content = reg:gsub("\n$", "")
            local lines = vim.split(content, "\n", { plain = true })
            buffer.with_suppressed_bytes(nb, function()
              vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, lines)
              -- The substitution collapsed cell.start_mark_id onto the
              -- next cell's anchor at row + #lines. Re-create it at the
              -- original row so this cell owns the pasted slice; the
              -- next cell's anchor is already where it needs to be.
              buffer.place_cell_anchor(bufnr, cell, row)
              buffer.refresh_after_mutation(bufnr, nb)
            end)
            vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
            return
          end
        end
      end
      vim.cmd("normal! " .. vim.v.count1 .. default_key)
    end
  end
  vim.keymap.set("n", "p", paste_in_empty_cell("p"),
    vim.tbl_extend("force", opts, { desc = "Marimo: smart paste (p)" }))
  vim.keymap.set("n", "P", paste_in_empty_cell("P"),
    vim.tbl_extend("force", opts, { desc = "Marimo: smart paste (P)" }))

  -- Phase 8.5: DataFrame side-panel for the cell under the cursor.
  if km.dataframe_panel then
    vim.keymap.set("n", km.dataframe_panel, function()
      if nb._flush_pending then nb._flush_pending() end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell = notebook.get_cell_at_row(nb, row)
      if cell then dataframe.open_for_cell(nb, cell) end
    end, o("Marimo: open DataFrame side-panel"))
  end

  -- ── Phase 10: widget interaction UX ──────────────────────────────────────

  local widget_picker = require("neo-marimo.widget_picker")

  local function cell_at_cursor()
    if nb._flush_pending then nb._flush_pending() end
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    return notebook.get_cell_at_row(nb, row)
  end

  -- Smart act: focused widget → direct, single-widget cell → direct,
  -- multi-widget cell → ordered picker.
  if km.widget_picker then
    vim.keymap.set("n", km.widget_picker, function()
      local cell = cell_at_cursor()
      if not cell then return end
      widget_picker.smart(nb, cell)
    end, o("Marimo: act on widget(s) in cell"))
  end

  if km.widget_picker_full then
    vim.keymap.set("n", km.widget_picker_full, function()
      local cell = cell_at_cursor()
      if not cell then return end
      widget_picker.open(nb, cell)
    end, o("Marimo: open widget picker"))
  end

  -- Focus cycling: ]w / [w move the ▸ marker through every widget in the
  -- notebook — cells top-to-bottom, widgets in document order within each
  -- cell, wrapping at the ends. The cursor follows the focused cell, and
  -- both the previously-focused cell and the new one repaint.
  local function focus_cycle(dir)
    local cur_cell = cell_at_cursor()
    local prev_focus = widgets.get_focus(bufnr)
    local target = widgets.next_focus_target(bufnr, nb.cells, cur_cell, dir)
    if not target then
      vim.notify("[neo-marimo] No widgets in any cell output.", vim.log.levels.INFO)
      return
    end
    widgets.set_focus(bufnr, target.cell.id, target.widget.object_id, target.index)
    if prev_focus and prev_focus.cell_id ~= target.cell.id then
      local pc = nb.cell_by_id[prev_focus.cell_id]
      if pc then output.render(bufnr, pc, nb.filepath) end
    end
    output.render(bufnr, target.cell, nb.filepath)
    -- Park the cursor on the cell's LAST line, not its first: the widgets
    -- are virt_lines attached below end_row, so jumping to the top of a
    -- tall cell would scroll them out of view. zz centers, leaving half a
    -- window for the output underneath.
    local row = math.min(target.cell.end_row + 1, vim.api.nvim_buf_line_count(bufnr))
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.cmd("normal! zz")
    vim.cmd("redraw")
  end

  if km.next_widget then
    vim.keymap.set("n", km.next_widget, function() focus_cycle(1) end,
      o("Marimo: focus next widget"))
  end
  if km.prev_widget then
    vim.keymap.set("n", km.prev_widget, function() focus_cycle(-1) end,
      o("Marimo: focus previous widget"))
  end

  if km.widget_last then
    vim.keymap.set("n", km.widget_last, function()
      if nb._flush_pending then nb._flush_pending() end
      widget_picker.act_last()
    end, o("Marimo: edit last-edited widget"))
  end

  if km.widget_pins then
    vim.keymap.set("n", km.widget_pins, function()
      if nb._flush_pending then nb._flush_pending() end
      widget_picker.open_pins(nb)
    end, o("Marimo: pinned widgets panel"))
  end

  if km.widget_pin then
    vim.keymap.set("n", km.widget_pin, function()
      local cell = cell_at_cursor()
      -- Pin target priority: the focused widget when it's in the cell
      -- under the cursor (a far-away focus must not hijack the pin), else
      -- a single-widget cursor cell, else the last-edited widget.
      local target, target_cell_id
      local fw, fcell_id = widgets.focused_widget(bufnr)
      if fw and cell and fcell_id == cell.id then
        target, target_cell_id = fw, fcell_id
      elseif cell then
        local list = widgets.list_for_cell(bufnr, cell.id)
        if #list == 1 then target, target_cell_id = list[1], cell.id end
      end
      if not target then
        local last = widgets.get_last()
        if last and last.nb == nb then
          for _, w in ipairs(widgets.list_for_cell(bufnr, last.cell_id)) do
            if w.object_id == last.object_id then
              target, target_cell_id = w, last.cell_id
              break
            end
          end
        end
      end
      if not target then
        vim.notify("[neo-marimo] Nothing to pin — focus a widget (]w) or edit one first.",
          vim.log.levels.INFO)
        return
      end
      local pinned = widgets.toggle_pin(nb.filepath, target_cell_id, target)
      if pinned == nil then
        vim.notify("[neo-marimo] Widget has no object-id; can't pin it.",
          vim.log.levels.WARN)
      else
        vim.notify("[neo-marimo] " .. (pinned and "Pinned " or "Unpinned ")
          .. target.label, vim.log.levels.INFO)
      end
    end, o("Marimo: pin/unpin widget"))
  end

  -- Nudge: step the focused slider/number/range with one key, no prompt.
  -- Only fires when the focused widget is in the cell under the cursor;
  -- otherwise the key is replayed unmapped so the native command (<C-a>
  -- increment / <C-x> decrement on the defaults) keeps working in code.
  local function bind_nudge(lhs, dir, desc)
    if not lhs then return end
    vim.keymap.set("n", lhs, function()
      local cell = cell_at_cursor()
      if cell and widget_picker.nudge(nb, cell, dir) then return end
      local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
      vim.api.nvim_feedkeys(vim.v.count1 .. keys, "n", false)
    end, o(desc))
  end
  bind_nudge(km.widget_nudge_up, 1, "Marimo: nudge widget up")
  bind_nudge(km.widget_nudge_down, -1, "Marimo: nudge widget down")
end

return M

-- neo-marimo plugin entry point
-- This file is sourced automatically when the plugin is on the runtimepath.

-- Add the plugin root to rtp so TreeSitter can find our injection queries
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
if not vim.tbl_contains(vim.opt.rtp:get(), plugin_root) then
  vim.opt.rtp:prepend(plugin_root)
end

-- Automatically detect and attach to marimo notebooks when opened
vim.api.nvim_create_autocmd("BufReadPost", {
  pattern = "*.py",
  group = vim.api.nvim_create_augroup("NeoMarimo", { clear = true }),
  callback = function(ev)
    -- Defer slightly so filetype detection runs first
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(ev.buf) then return end

      local marimo = require("neo-marimo")

      -- Only process if not already a notebook buffer
      local bufname = vim.api.nvim_buf_get_name(ev.buf)
      if bufname:match("^marimo://") then return end

      if marimo.is_marimo_notebook(ev.buf) then
        -- Auto-setup with defaults if user hasn't called setup()
        if not require("neo-marimo.config").options.python_path then
          marimo.setup({})
        end
        marimo.attach(ev.buf)
      end
    end)
  end,
})

-- User commands
vim.api.nvim_create_user_command("MarimoOpen", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  local marimo_cmd = require("neo-marimo.config").options.marimo_cmd or "marimo"
  vim.fn.jobstart({ marimo_cmd, "edit", nb.filepath }, { detach = true })
  vim.notify("[neo-marimo] Opening " .. vim.fn.fnamemodify(nb.filepath, ":t") .. " in browser...", vim.log.levels.INFO)
end, { desc = "Open current marimo notebook in browser" })

vim.api.nvim_create_user_command("MarimoReload", function()
  local marimo = require("neo-marimo")
  local nb = marimo.current_notebook()
  if not nb then
    vim.notify("[neo-marimo] Not in a marimo notebook buffer", vim.log.levels.WARN)
    return
  end
  require("neo-marimo.sync").reload_from_file(nb)
  vim.notify("[neo-marimo] Reloaded from disk", vim.log.levels.INFO)
end, { desc = "Reload marimo notebook from disk" })

vim.api.nvim_create_user_command("MarimoAttach", function()
  -- Manually attach to current buffer (in case auto-detection missed it)
  local bufnr = vim.api.nvim_get_current_buf()
  require("neo-marimo").attach(bufnr)
end, { desc = "Attach neo-marimo to current Python buffer" })

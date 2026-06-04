-- blink.cmp source for neo-marimo notebooks.
--
-- Opt-in via the user's blink.cmp config (see doc/neo-marimo.txt for the
-- exact snippet). When the cursor is on a `marimo://` buffer, completion
-- requests are routed through the existing shadow-buffer LSP path used
-- by <C-x><C-o> — same pyright client, same in-memory shadow content,
-- same workspace resolution.
--
-- On non-notebook buffers the source short-circuits via `:enabled()`, so
-- this module can sit in the user's `sources.default` list without
-- affecting regular .py completion behavior.
--
-- Items are LSP CompletionItem objects passed through unchanged. blink
-- consumes that shape natively (`label`, `kind`, `insertText`,
-- `documentation`, `textEdit`, …), so we don't translate fields.

local M = {}

-- blink will call `Source.new(opts, config)` per provider; we accept no
-- options today but follow the expected shape so future opts (e.g.
-- `trigger_characters`) slot in without an API change.
function M.new(_opts, _config)
  return setmetatable({}, { __index = M })
end

-- Scoping: only fire on `marimo://` buffers. Without this guard, blink
-- would query the source for every buffer and the per-call `enabled`
-- check inside get_completions would still gate it, but the framework
-- API is meant for this kind of pre-filter.
function M:enabled()
  local name = vim.api.nvim_buf_get_name(0)
  return name:match("^marimo://") ~= nil
end

-- Trigger characters tell blink to invoke the source on `.`, `:`, etc.
-- without waiting for keystrokes that match a configured pattern. Match
-- pyright's trigger set so the user sees attribute completion the
-- moment they type `np.`.
function M:get_trigger_characters()
  return { ".", "[", "\"", "'" }
end

-- Main entry point. blink calls this with the completion context and
-- expects `callback({ is_incomplete_forward, is_incomplete_backward,
-- items })`. We:
--   1. Resolve the notebook the cursor sits on.
--   2. Refresh the shadow (synthetic didChange under textlock — see
--      lsp.lua's refresh_shadow).
--   3. Verify a Python LSP is attached to the shadow; if not, no-op.
--   4. Suppress requests in markdown-cell bodies.
--   5. Translate cursor position into the shadow's coordinate space.
--   6. Fire textDocument/completion against the shadow buffer with the
--      computed position, and surface the items back to blink.
function M:get_completions(_ctx, callback)
  local lsp = require("neo-marimo.lsp")
  local nb = require("neo-marimo").current_notebook()
  if not nb then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local entry = lsp.refresh_shadow(nb)
  if not entry then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local clients = vim.lsp.get_clients({ bufnr = entry.bufnr })
  if #clients == 0 then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]

  if lsp.is_in_markdown_string(nb.bufnr or 0, row, col) then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local shadow_row, shadow_col = lsp.notebook_to_shadow_pos(nb, entry, row, col)
  if not shadow_row then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(entry.bufnr),
    position = { line = shadow_row, character = shadow_col },
  }

  -- Track which client served each item so :resolve below can route
  -- completionItem/resolve to the same one. blink hands the item back
  -- on resolve without saying who served it, so we have to stash that
  -- ourselves.
  local items = {}
  local pending = #clients
  local sent = false

  local function finish()
    if sent then return end
    sent = true
    callback({
      items = items,
      -- pyright may return isIncomplete=true on partial-prefix requests;
      -- blink uses these flags to decide whether to re-query as the
      -- user keeps typing. Forward "incomplete forward" for safety.
      is_incomplete_forward = true,
      is_incomplete_backward = false,
    })
  end

  for _, client in ipairs(clients) do
    client:request("textDocument/completion", params, function(_err, result)
      pending = pending - 1
      local list = (result and result.items) or result or {}
      if type(list) == "table" then
        for _, item in ipairs(list) do
          item.client_id = client.id
          table.insert(items, item)
        end
      end
      if pending <= 0 then finish() end
    end, entry.bufnr)
  end

  -- Safety net: if no client responds within 600ms, return whatever
  -- arrived. blink can re-query as the user keeps typing.
  vim.defer_fn(finish, 600)
end

-- Lazy resolution of an item's full docs / additionalTextEdits. blink
-- calls this when the user hovers over an item in the menu. We route
-- completionItem/resolve to the same client that produced the item
-- (stamped in `client_id` during get_completions).
function M:resolve(item, callback)
  local lsp = require("neo-marimo.lsp")
  local nb = require("neo-marimo").current_notebook()
  if not nb then callback(item); return end
  local entry = lsp.refresh_shadow(nb)
  if not entry then callback(item); return end

  local client
  if item.client_id then
    client = vim.lsp.get_client_by_id(item.client_id)
  end
  if not client then
    -- Fall back to the first python client attached to the shadow.
    client = (vim.lsp.get_clients({ bufnr = entry.bufnr }) or {})[1]
  end
  if not client or not client.supports_method
      or not client:supports_method("completionItem/resolve") then
    callback(item)
    return
  end

  client:request("completionItem/resolve", item, function(_err, resolved)
    callback(resolved or item)
  end, entry.bufnr)
end

return M

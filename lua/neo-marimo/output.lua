-- Cell output rendering via extmark virtual lines.
-- Handles the cell-op messages from the marimo WebSocket.

local hl = require("neo-marimo.highlights")
local config = require("neo-marimo.config")
local markdown = require("neo-marimo.markdown")
local image = require("neo-marimo.image")
local widgets = require("neo-marimo.widgets")
local dataframe = require("neo-marimo.dataframe")
local server = require("neo-marimo.server")
local tree_render = require("neo-marimo.tree_render")
local log = require("neo-marimo.log")
local utils = require("neo-marimo.utils")

local M = {}

-- Maximum output lines to show per cell before truncating.
local MAX_LINES = 30

-- Hard cap on the byte length of any single text payload / virt_line chunk we
-- attempt to render. No inline cell display can use kilobytes of text on one
-- line, and the word-wrapper (wrap_virt_line) is O(n²) in the chunk length —
-- so a stray large string (a base64 image blob that missed the image path, a
-- giant repr) would otherwise freeze the editor for minutes. 16 KiB is far
-- more than the MAX_LINES cap can ever show; anything past it is truncated.
local MAX_OUTPUT_BYTES = 16 * 1024

-- plan-refinement F2.3: cell.console accumulates one entry per cell-op that
-- carries console data — a print-heavy loop (e.g. `for i in range(...): print(i)`
-- inside one cell) drives many cell-ops, each appending a single entry, so the
-- list grows without bound for the life of the buffer. Two caps address the
-- two costs: MAX_CONSOLE_ENTRIES bounds the *stored* list (memory — see the
-- append site in M.handle_cell_op), MAX_CONSOLE_LINES bounds what gets
-- *repainted* on every M.render pass (paint cost — see the console loop
-- below). Both mirror MAX_OUTPUT_BYTES's rationale: without them, a
-- print-heavy cell reopens the same freeze scenario MAX_OUTPUT_BYTES was
-- written to prevent, just paid across many small entries/lines instead of
-- one oversized string.
local MAX_CONSOLE_ENTRIES = 200
-- Value coincidentally matches MAX_LINES above — the two caps bound
-- different things (console repaint vs. output display budget) and aren't
-- meant to be kept in lockstep; change either independently as needed.
local MAX_CONSOLE_LINES = 30

-- Phase 8.2 / 8.5: image and widget output frequently arrives bigger than
-- the inline cap (matplotlib figures are tall; DataFrames have many rows).
-- Both have dedicated viewers (image.nvim handles plot rendering inline,
-- :MarimoDataFramePanel opens the full table), so we keep the inline cap
-- modest and rely on the side paths for "show me everything".
local MAX_DATAFRAME_INLINE_ROWS = 5

-- Per-cell render context: bufnr and cell_id are forwarded to renderers so
-- the widget registry can be keyed properly. Stored as a module-level
-- variable since render is called from a hot path and threading it through
-- every renderer signature would be a lot of plumbing for one optional
-- side-effect. tree_render writes `image_drawn` and `skip_cap` back into it,
-- and saves/restores `object_id`/`tab` as it recurses (all reset per-cell at
-- the top of M.render).
local _render_ctx = {
  bufnr = nil, cell_id = nil, row = nil, filepath = nil,
  image_drawn = false, skip_cap = false, object_id = nil, tab = nil,
}

-- ── Renderer registry ──────────────────────────────────────────────────────
--
-- Each renderer takes (data, opts) and returns a list of virt_line chunk lists
-- (i.e. a list where each element is itself a list of {text, hl_group} pairs).
-- `data` is the payload from the CellOutput. `opts` (plan-refinement F4.3) is
-- the render context for this call, so a third-party renderer registered via
-- M.register_renderer can draw an image or register a widget without reaching
-- into any private module state:
--   opts.bufnr     buffer the cell lives in
--   opts.cell_id   the cell's id (widget registry key, image placement key)
--   opts.row       0-indexed row output/images anchor at (cell.end_row)
--   opts.filepath  notebook path, for fetching server-hosted virtual files
-- Built-in renderers still read these off the private _render_ctx upvalue
-- (image_drawn/skip_cap out-params live there too, and aren't part of this
-- public opts contract); the fields above are just the same values handed to
-- every renderer, built-in or third-party, at every dispatch site.

-- Local, not `M.renderers` / `M.renderer_patterns` (plan-refinement F4.4):
-- the registry storage isn't part of the frozen public surface —
-- M.register_renderer is the only supported write path (mirrors widgets.lua's
-- local RENDERERS).
local renderers = {}

-- Lookup order for prefix matches like `image/png` → `image/*`. We try the
-- exact mimetype first, then any registered prefix patterns in order.
local renderer_patterns = {}

-- Register a renderer for an exact mimetype (e.g. "text/plain") or a pattern
-- ending in `/*` (e.g. "image/*"). Patterns are matched after exact
-- mimetypes. Passing `fn = nil` deregisters: an exact mimetype's entry is
-- dropped, or every pattern sharing that prefix is removed. This is the only
-- deregister path now that the tables above are local (plan-refinement
-- F4.4) — needed by tests that register a throwing renderer (F4.1) and must
-- clean it up so later specs render against the stock table. Mirrors
-- ws_handlers.register / widgets.register_renderer's nil-to-remove contract.
function M.register_renderer(mime, fn)
  if mime:sub(-2) == "/*" then
    -- strip the trailing "*", keep the "/" so "image/*" stores prefix "image/"
    local prefix = mime:sub(1, -2)
    if fn == nil then
      for i = #renderer_patterns, 1, -1 do
        if renderer_patterns[i].prefix == prefix then table.remove(renderer_patterns, i) end
      end
      return
    end
    table.insert(renderer_patterns, { prefix = prefix, fn = fn })
  else
    renderers[mime] = fn
  end
end

local function lookup_renderer(mime)
  if renderers[mime] then return renderers[mime] end
  for _, p in ipairs(renderer_patterns) do
    if mime:sub(1, #p.prefix) == p.prefix then
      return p.fn
    end
  end
  return nil
end

-- The opts table handed to every renderer at dispatch (plan-refinement
-- F4.3) — a snapshot of the current cell's render context so third-party
-- renderers get the same bufnr/cell_id/row/filepath the built-ins read off
-- _render_ctx directly.
local function current_opts()
  return {
    bufnr = _render_ctx.bufnr,
    cell_id = _render_ctx.cell_id,
    row = _render_ctx.row,
    filepath = _render_ctx.filepath,
  }
end

-- Per-mime error counts for the containment below (plan-refinement F4.1),
-- mirroring ws_handlers' once-per-op pattern. Exposed for tests.
M._renderer_errors = {}

-- pcall-wrap a renderer call so a throwing renderer (built-in or
-- third-party, registered via M.register_renderer) can't take the rest of
-- rendering down with it. Before this wrapper, a throw here propagated all
-- the way up into the cell-op WS handler, where ws_handlers.dispatch's own
-- pcall caught it — but that pcall then suppressed *every other* op with a
-- misattributed "WS handler for 'cell-op' failed" warning, since it had no
-- way to know the failure actually came from a renderer several calls
-- deeper. Worse, M.render clears ns_output before building new virt_lines
-- (see M.render below), so a throw mid-build left the cell silently blank
-- with no on-screen sign anything had gone wrong. Returning a placeholder
-- line here instead keeps the failure visible and scoped to just this one
-- mime/cell, and lets every other cell keep rendering normally.
local function safe_render(mime, fn, ...)
  local ok, result = pcall(fn, ...)
  if ok then return result end
  M._renderer_errors[mime] = (M._renderer_errors[mime] or 0) + 1
  if M._renderer_errors[mime] == 1 then
    utils.warn(
      "Output renderer for '" .. tostring(mime) .. "' failed: " .. tostring(result)
        .. "\nFurther failures for this mimetype will be suppressed."
    )
  end
  log.write("output:renderer_error", { mime = mime, err = tostring(result) })
  return { { { "  ✖ renderer error: " .. tostring(mime), "MarimoOutputError" } } }
end

-- ── Built-in renderers ─────────────────────────────────────────────────────

local function render_text_plain(data)
  if type(data) ~= "string" then
    data = tostring(data)
  end
  local truncated = false
  if #data > MAX_OUTPUT_BYTES then
    data = data:sub(1, MAX_OUTPUT_BYTES)
    -- Drop a dangling UTF-8 continuation tail left by the byte-wise cut so the
    -- last visible character stays valid.
    data = data:gsub("[\128-\191]*$", "")
    truncated = true
  end
  local lines = {}
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, { { "  " .. line, "MarimoOutputText" } })
  end
  if truncated then
    table.insert(lines, { { "  … [output truncated — too large to display inline]", "Comment" } })
  end
  return lines
end

local function render_error(data)
  -- data is a list of Error objects: [{type, msg, frames}]
  local lines = {}
  if type(data) == "table" then
    for _, err in ipairs(data) do
      local etype = (type(err) == "table" and err.type) or "Error"
      local msg = (type(err) == "table" and err.msg) or tostring(err)
      table.insert(lines, { { "  ✖ " .. etype .. ": " .. msg, "MarimoOutputError" } })
    end
  else
    table.insert(lines, { { "  ✖ " .. tostring(data), "MarimoOutputError" } })
  end
  return lines
end

local function render_html(data)
  -- Routing pass for HTML payloads. Marimo wraps a lot of different things
  -- in text/html — payloads with *structure* (marimo custom elements, HTML
  -- tables, flex layouts) parse into an element tree and render per node
  -- (tree_render.lua), so e.g. a tabs container holding a table renders as
  -- tabs with a table inside instead of the table hijacking the whole cell.
  --
  -- Everything else takes the fast string path:
  --   1. Markdown wrapper   (mo.md output)                → markdown module
  --   2. Embedded data:image/...;base64 (matplotlib)      → image module
  --   3. Inline <svg> markup                              → image module
  --   4. Server-hosted virtual-file <img> (mo.image)      → image module
  --   5. Anything else                                    → strip tags fallback
  if type(data) ~= "string" then return {} end

  if tree_render.wants(data) then
    return tree_render.render(data, _render_ctx)
  end

  if markdown.looks_like_marimo_md_html(data) then
    return markdown.render(data)
  end

  if image.has_embedded_image(data) then
    local mime, b64 = image.extract_data_uri(data)
    if mime and b64 then
      local lines = image.render_base64(_render_ctx.bufnr, _render_ctx.row or 0, mime, b64, _render_ctx.cell_id)
      -- Set image_drawn only AFTER render succeeds (plan-refinement F4.1
      -- review). render_html is dispatched through safe_render's pcall, so a
      -- throwing image.render_* here is caught and shown as the "✖ renderer
      -- error" placeholder — but if image_drawn had already flipped true
      -- *before* the call, M.render's orphan-image cleanup (image.clear_for_
      -- cell, gated on image_drawn == false) would never fire, and the
      -- previous successful render's placement would silently linger next to
      -- the error placeholder. Setting it after a successful return lets a
      -- throw fall through to that cleanup like any other image-less render.
      _render_ctx.image_drawn = true
      return lines
    end
  end

  -- Inline <svg> markup (mo.Html(svg), mo.md with embedded SVG). Rasterise it
  -- through the image path rather than stripping the tags to nothing.
  local svg = image.extract_inline_svg(data)
  if svg then
    local lines = image.render_at(_render_ctx.bufnr, _render_ctx.row or 0,
      "image/svg+xml", svg, _render_ctx.cell_id)
    _render_ctx.image_drawn = true  -- set after success — see the embedded-image branch above
    return lines
  end

  -- Server-hosted virtual-file image (mo.image, etc.): the <img src> points at
  -- "./@file/…" and the bytes live on the marimo server. Fetch and render them.
  local vf = image.extract_virtual_file(data)
  if vf and _render_ctx.filepath then
    local filepath = _render_ctx.filepath
    local lines = image.render_url(_render_ctx.bufnr, _render_ctx.row or 0, vf, _render_ctx.cell_id,
      function(dest) return server.fetch_virtual_file(filepath, vf, dest) end)
    _render_ctx.image_drawn = true  -- set after success — see the embedded-image branch above
    return lines
  end

  -- Fallback: strip remaining tags. Surface SVG/<img> as a placeholder so
  -- the user knows there's content their terminal couldn't render.
  local lines = {}
  local has_image = data:find("<img[^%w]") or data:find("<svg[^%w]")
  if has_image then
    table.insert(lines, { { "  [image — install image.nvim or open in browser]", "Comment" } })
  end
  local stripped = require("neo-marimo.html").decode_entities(data:gsub("<[^>]+>", ""))
  stripped = stripped:match("^%s*(.-)%s*$")
  if stripped ~= "" then
    for _, vl in ipairs(render_text_plain(stripped)) do
      table.insert(lines, vl)
    end
  end
  return lines
end

local function render_dataresource(data)
  -- Delegate to dataframe.lua so the inline preview and the side panel
  -- share one extractor and one renderer — keeps column widths, sort
  -- arrow placement, and the "<leader>mD for full panel" hint in sync.
  local df = dataframe.parse_dataresource(data)
  return dataframe.render_inline(df, { max_rows = MAX_DATAFRAME_INLINE_ROWS })
end

local function render_image(data, _opts, mime)
  -- Marimo encodes image/* payloads as base64 strings.
  local lines = image.render_base64(_render_ctx.bufnr, _render_ctx.row or 0,
    mime or "image/png", tostring(data or ""), _render_ctx.cell_id)
  _render_ctx.image_drawn = true  -- set after success — see render_html's embedded-image branch above
  return lines
end

local function render_svg(data)
  -- SVG arrives as XML text. Most terminal image protocols can't render
  -- SVG directly; image.nvim can with the right backend, snacks.image can
  -- too. We pass the raw bytes through the image module which will write
  -- the SVG to a file — backends that can rasterize it will, the rest will
  -- show the file-path placeholder.
  if type(data) ~= "string" then return {} end
  local lines = image.render_at(_render_ctx.bufnr, _render_ctx.row or 0,
    "image/svg+xml", data, _render_ctx.cell_id)
  _render_ctx.image_drawn = true  -- set after success — see render_html's embedded-image branch above
  return lines
end

local function render_markdown_mime(data)
  -- markdown.render auto-detects HTML wrappers (`<span class="markdown
  -- prose">`) and unwraps them before rendering — necessary because marimo
  -- (≥ 0.19) serializes mo.md() output as pre-rendered HTML wearing a
  -- text/markdown sticker, so the payload can't be treated as raw markdown.
  return require("neo-marimo.markdown").render(data)
end

local function render_marimo_mime(data)
  -- application/vnd.marimo+mime is a JSON envelope: {mimetype, data}.
  -- Route the inner payload through the standard lookup so e.g. a widget
  -- wrapped in a mime envelope reaches the widget renderer.
  if type(data) == "table" and data.mimetype then
    local renderer = M._lookup_renderer(data.mimetype)
    if renderer then return safe_render(data.mimetype, renderer, data.data, current_opts()) end
  end
  -- Marimo also uses this mimetype as a fallback for things it can't
  -- otherwise type — show the inner mime/data hint so the user knows what
  -- they're missing.
  return { {
    { "  [marimo widget — ", "Comment" },
    { (type(data) == "table" and data.mimetype) or "unknown", "MarimoWidgetLabel" },
    { "]", "Comment" },
  } }
end

local function render_application_json(data)
  -- application/json is marimo's format for tuple/sequence cell outputs.
  -- The data is a JSON-encoded array where each element is a string of the
  -- form "mimetype:content" (e.g. "text/html:<marimo-table ...>").
  -- Decode the array and dispatch each item through the standard renderer
  -- lookup so e.g. two DataFrames returned as a tuple both render as inline
  -- tables instead of being dumped as a raw JSON blob.
  local decoded
  if type(data) == "string" then
    local ok, result = pcall(vim.json.decode, data,
      { luanil = { object = true, array = true } })
    if ok then
      decoded = result
    else
      return render_text_plain(data)
    end
  elseif type(data) == "table" then
    decoded = data
  else
    return render_text_plain(tostring(data))
  end

  -- Check for the "mimetype:content" list format. Valid MIME types look like
  -- "type/subtype" (with optional dots/plusses), so require at least one "/"
  -- before the first ":" to avoid false-positives on other JSON arrays.
  if type(decoded) == "table" and decoded[1] ~= nil then
    local is_mime_list = true
    for _, item in ipairs(decoded) do
      if type(item) ~= "string" or not item:find("^[%w%-]+/[%w%-%.%+]+:") then
        is_mime_list = false
        break
      end
    end

    if is_mime_list then
      _render_ctx.skip_cap = true
      local out = {}
      for i, item in ipairs(decoded) do
        local colon = item:find(":")
        local mime = item:sub(1, colon - 1)
        local content = item:sub(colon + 1)
        local renderer = lookup_renderer(mime)
        if renderer then
          local lines = safe_render(mime, renderer, content, current_opts(), mime)
          for _, line in ipairs(lines) do table.insert(out, line) end
        else
          for _, line in ipairs(render_text_plain(content)) do
            table.insert(out, line)
          end
        end
        if i < #decoded then
          table.insert(out, { { "  ", "MarimoOutputText" } })
        end
      end
      return out
    end
  end

  -- Fallback for other JSON shapes: render as plain text.
  if type(data) == "string" then return render_text_plain(data) end
  return {}
end

-- Register built-ins. mo.md() emits text/html with a `<span class="markdown
-- prose ...">` wrapper; render_html detects that shape and forwards to the
-- markdown renderer (Phase 8.1). Raw text/markdown payloads (rare but
-- possible) route straight to render_markdown_mime.
M.register_renderer("text/plain", render_text_plain)
M.register_renderer("text/html", render_html)
M.register_renderer("text/markdown", render_markdown_mime)
M.register_renderer("application/json", render_application_json)
M.register_renderer("application/vnd.dataresource+json", render_dataresource)
M.register_renderer("application/vnd.marimo+error", render_error)
M.register_renderer("application/vnd.marimo+mime", render_marimo_mime)
M.register_renderer("image/svg+xml", render_svg)
M.register_renderer("image/*", render_image)

-- Internal: expose lookup so renderers (like render_marimo_mime) can
-- delegate to the registered handler for a nested mimetype.
function M._lookup_renderer(mime) return lookup_renderer(mime) end

-- Some rich outputs (matplotlib via `_repr_mimebundle_`, and other libraries
-- that emit a mimebundle) arrive under a non-HTML mimetype carrying their
-- image as a `data:image/...;base64,...` URI — e.g. the data field is the
-- string `{"image/png": "data:image/png;base64,..."}`, or a decoded table
-- keyed by mimetype. render_html only extracts data URIs from text/html, so
-- these slip through to the plain-text dump. Detect and unwrap them here.
local function extract_embedded_image(data)
  if type(data) == "string" then
    return image.extract_data_uri(data)
  end
  if type(data) == "table" then
    for _, key in ipairs({ "image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp" }) do
      local v = data[key]
      if type(v) == "string" and v ~= "" then
        -- The value is either a full data: URI or bare base64 under the
        -- mimetype key. Try the URI form first, fall back to bare base64.
        local mime, b64 = image.extract_data_uri(v)
        if mime then return mime, b64 end
        return key, v
      end
    end
  end
  return nil
end

-- Convert a CellOutput object (from the WS message) to virt_lines chunks.
local function output_to_virt_lines(output)
  if not output then return {} end

  local mimetype = output.mimetype or "text/plain"
  local data = output.data

  -- Marimo sends `output: {mimetype: "text/plain", data: ""}` for cells
  -- with no return value (assignments, prints, defs). Treat empty string
  -- payloads as "no output" so we don't render a blank line.
  if type(data) == "string" and data == "" then
    return {}
  end

  local renderer = lookup_renderer(mimetype)
  -- render_text_plain is the only renderer we let an embedded-image probe
  -- override — every other renderer (html, markdown, dataframe, image/*) does
  -- its own, more specific routing that we must not pre-empt.
  if renderer and renderer ~= render_text_plain then
    -- Pass the matched mimetype as the third arg so pattern renderers
    -- (image/*) can branch on the specific subtype.
    return safe_render(mimetype, renderer, data, current_opts(), mimetype)
  end

  -- text/plain or unknown mime: unwrap an embedded image if present, else
  -- fall back to dumping as text.
  local img_mime, img_data = extract_embedded_image(data)
  if img_mime and img_data then
    local lines = image.render_base64(_render_ctx.bufnr, _render_ctx.row or 0, img_mime, img_data, _render_ctx.cell_id)
    _render_ctx.image_drawn = true  -- set after success — see render_html's embedded-image branch above
    return lines
  end

  if type(data) == "string" then
    return render_text_plain(data)
  end
  return { { { "  [" .. mimetype .. "]", "Comment" } } }
end

-- ── output wrapping ────────────────────────────────────────────────────────
--
-- virt_lines neither wrap nor scroll horizontally: anything past the right
-- window edge is simply invisible, with no way to reach it. So every
-- virt_line is hard-wrapped at the window's text width before the extmark
-- is set. Highlights are preserved per chunk; continuation lines start with
-- the standard two-space indent. Prose breaks at word boundaries when one
-- falls inside the overflowing chunk.

-- Split `text` at the largest codepoint prefix that fits in `cells` display
-- cells (multi-byte safe — box-drawing chars are 3 bytes / 1 cell).
local function fit_chars(text, cells)
  local total = vim.fn.strchars(text)
  local lo, hi = 0, total
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, mid)) <= cells then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return vim.fn.strcharpart(text, 0, lo), vim.fn.strcharpart(text, lo)
end

-- Wrap one virt_line (list of {text, hl} chunks) at `width` display cells.
-- Returns a list of virt_lines. Exposed as M._wrap_virt_line for tests.
local function wrap_virt_line(chunks, width)
  width = math.max(width, 12)

  -- Backstop: truncate any single chunk longer than the output cap before the
  -- char-by-char wrap below. The wrap is O(n²) in chunk length, so without
  -- this a stray huge chunk (a base64 blob that bypassed render_text_plain's
  -- own cap, e.g. via the strip-tags HTML fallback) would freeze the editor.
  -- The slack past MAX_OUTPUT_BYTES keeps an already-capped text line (which
  -- carries a 2-space prefix) from re-triggering and double-marking.
  for i, ch in ipairs(chunks) do
    if type(ch[1]) == "string" and #ch[1] > MAX_OUTPUT_BYTES + 256 then
      chunks[i] = { vim.fn.strcharpart(ch[1], 0, MAX_OUTPUT_BYTES) .. " …", ch[2] }
    end
  end

  local total = 0
  for _, ch in ipairs(chunks) do
    total = total + vim.fn.strdisplaywidth(ch[1])
  end
  if total <= width then return { chunks } end

  local out = {}
  local cur, cur_w, start_w = {}, 0, 0
  local function flush()
    table.insert(out, cur)
    cur = { { "  ", "MarimoOutputText" } }
    cur_w = 2
    start_w = 2
  end

  for _, ch in ipairs(chunks) do
    local text, hl_group = ch[1], ch[2]
    while text ~= "" do
      local avail = width - cur_w
      if vim.fn.strdisplaywidth(text) <= avail then
        table.insert(cur, { text, hl_group })
        cur_w = cur_w + vim.fn.strdisplaywidth(text)
        break
      end

      local head, tail = fit_chars(text, avail)

      -- Mid-word split? Pull the partial word onto the next line when the
      -- kept part still has content without it.
      if head ~= "" and tail ~= ""
          and head:sub(-1):match("%S") and tail:sub(1, 1):match("%S") then
        local cut = head:match("^(.*)%s%S+$")
        if cut and cut:find("%S") then
          tail = head:sub(#cut + 2) .. tail
          head = cut
        end
      end

      if head == "" then
        if cur_w > start_w then
          -- Line already holds content; wrap and retry with a fresh line.
          flush()
        else
          -- A single codepoint wider than the available space (pathological
          -- narrow window): force one through so we always make progress.
          head = vim.fn.strcharpart(text, 0, 1)
          table.insert(cur, { head, hl_group })
          flush()
          text = vim.fn.strcharpart(text, 1)
        end
      else
        table.insert(cur, { head, hl_group })
        flush()
        -- Continuation alignment is already broken by the wrap; leading
        -- whitespace would just smear it further right.
        text = tail:gsub("^%s+", "")
      end
    end
  end

  if cur_w > start_w or #out == 0 then table.insert(out, cur) end
  return out
end

M._wrap_virt_line = wrap_virt_line

-- Display width available for output text in the first window showing
-- `bufnr` (window width minus sign/number/fold columns). nil when the
-- buffer isn't visible — renders can land while another buffer has the
-- window; wrapping is then deferred to the WinResized/BufWinEnter repaint.
local function output_text_width(bufnr)
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then return nil end
  local win = wins[1]
  local width = vim.api.nvim_win_get_width(win)
  local info = vim.fn.getwininfo(win)[1]
  if info and info.textoff then width = width - info.textoff end
  return math.max(20, width)
end

-- Status indicator line at the top of each cell's output area.
-- `has_run` lets us distinguish "never executed" (no indicator) from
-- "executed successfully but produced no output" (✓ ran).
local function status_virt_line(status, has_run)
  if status == "running" then
    return { { "  ⟳ running", "MarimoStatusRunning" } }
  elseif status == "queued" then
    return { { "  ⟳ queued", "MarimoStatusRunning" } }
  elseif status == "error" then
    return { { "  ✖ error", "MarimoStatusError" } }
  elseif status == "idle" and has_run then
    return { { "  ✓ ran", "MarimoStatusOk" } }
  end
  return nil
end

-- ── viewport freeze across a render pass ────────────────────────────────────
--
-- A cell's output re-renders several times per run (queued → running → idle
-- w/ output), each pass replacing the cell's virt_lines with a different line
-- count (a 1-line "⟳ running" placeholder vs. the final N-line image). When
-- the cursor sits *below* the cell, that transient height change shifts how
-- many screen rows separate `topline` and the cursor, and Neovim's own
-- keep-cursor-visible logic reacts by nudging `topline` — the image and
-- everything below it visibly scrolls up, then back down once the final
-- output resettles. Cursor *above* the cell is unaffected (the virt_lines
-- sit below the cursor, so they never factor into the topline↔cursor span),
-- which is exactly the asymmetry this was reported with. Snapshotting each
-- window's topline before the mutation and restoring it right after — inside
-- the same synchronous call, before Neovim's next redraw — keeps the
-- viewport pinned through the whole queued/running/idle sequence instead of
-- fighting the user's chosen scroll position on every intermediate frame.
local function capture_toplines(bufnr)
  local saved = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
    if ok then saved[win] = view.topline end
  end
  return saved
end

local function restore_toplines(saved)
  for win, topline in pairs(saved) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_call, win, function()
        vim.fn.winrestview({ topline = topline })
      end)
    end
  end
end

-- ── Public API ──────────────────────────────────────────────────────────────

-- Render (or clear) the output for a cell.
-- `cell` must have `.end_row` set correctly. `filepath` (optional) is the
-- notebook path, used to fetch server-hosted virtual-file images.
function M.render(bufnr, cell, filepath)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local saved_toplines = capture_toplines(bufnr)

  -- Clear previous output marks for this cell's row range
  vim.api.nvim_buf_clear_namespace(
    bufnr, hl.ns_output,
    cell.start_row, cell.end_row + 1
  )

  -- Prime the per-cell render context so image/widget renderers can
  -- attach (image.nvim placements, widget registry keys) against the
  -- right buffer/cell. The renderer body reads from _render_ctx
  -- synchronously, so it's safe to leave the value in place for the
  -- duration of this M.render call.
  _render_ctx.bufnr = bufnr
  _render_ctx.cell_id = cell.id
  _render_ctx.row = cell.end_row
  _render_ctx.filepath = filepath
  -- Track whether this pass draws an inline image. If not, any image this
  -- cell drew on a previous run (e.g. it now returns a DataFrame instead of a
  -- plot) must be torn down so it doesn't linger as an orphaned placement.
  _render_ctx.image_drawn = false
  -- Set by tree_render when the payload renders widgets/layouts (which
  -- expand to many virt_lines and must not be chopped by the line cap).
  _render_ctx.skip_cap = false
  -- object_id/tab are transient walk state tree_render saves/restores as it
  -- recurses (marimo-ui-element scoping, tabs body identity — see
  -- tree_render.lua's ctx docstring). A throw mid-walk (now contained by
  -- render_node's own pcall, plan-refinement F4.1) can skip that restore,
  -- so reset both here too — otherwise a leftover object_id/tab from a
  -- failed pass could get misattributed to an unrelated widget on the very
  -- next render.
  _render_ctx.object_id = nil
  _render_ctx.tab = nil
  -- The render walk re-registers every widget it encounters, so the cell's
  -- previous set is dropped up front — a cell whose output stops containing
  -- widgets also stops listing them in :MarimoWidget.
  widgets.clear_for_cell(bufnr, cell.id)

  local virt_lines = {}

  -- Status line (idle only shown once cell has actually been executed)
  local status_line = status_virt_line(cell.status, cell._has_run)
  if status_line then
    table.insert(virt_lines, status_line)
  end

  -- Output content. Skip the output cap when the cell has a layout/widget
  -- payload — those expand to many virt_lines per widget and the cap
  -- would chop the bottom of a stacked layout, leaving a misleading
  -- partial display. Plain text/dataframe output keeps the cap as before.
  -- (_render_ctx.skip_cap is set during output_to_virt_lines by tree_render.)
  if cell.output then
    local output_lines = output_to_virt_lines(cell.output)
    local skip_cap = _render_ctx.skip_cap
    local shown = 0
    for _, vl in ipairs(output_lines) do
      if not skip_cap and shown >= MAX_LINES then
        -- Point at every escape hatch: hide/show toggle, browser, and —
        -- when the payload actually holds a table — the dataframe panel.
        local km = config.options.keymaps or {}
        local hint = "  … (output truncated — "
          .. (km.toggle_output or "<leader>mt") .. " hides it, "
          .. (km.open_in_browser or "<leader>mo") .. " opens the browser"
        if dataframe.extract_from_output(cell.output) then
          hint = hint .. ", " .. (km.dataframe_panel or "<leader>mD") .. " shows the full table"
        end
        table.insert(virt_lines, { { hint .. ")", "Comment" } })
        break
      end
      table.insert(virt_lines, vl)
      shown = shown + 1
    end
  end

  -- Console output (stdout/stderr printed during execution). Line-capped at
  -- MAX_CONSOLE_LINES (see the constant's comment above) so a print-heavy
  -- cell doesn't repaint an ever-growing console block on every render pass.
  if cell.console and #cell.console > 0 then
    local shown = 0
    local truncated = false
    for _, cout in ipairs(cell.console) do
      if not truncated and cout.data and cout.data ~= "" then
        local console_lines = render_text_plain(cout.data)
        for _, vl in ipairs(console_lines) do
          if shown >= MAX_CONSOLE_LINES then
            truncated = true
            break
          end
          table.insert(virt_lines, vl)
          shown = shown + 1
        end
      end
    end
    if truncated then
      table.insert(virt_lines, { { "  … [console output truncated]", "Comment" } })
    end
  end

  -- No image this pass → drop any placement this cell left behind earlier.
  if not _render_ctx.image_drawn then
    image.clear_for_cell(bufnr, cell.id)
  end

  if #virt_lines == 0 then
    restore_toplines(saved_toplines)
    return
  end

  -- Wrap every line at the window's text width so nothing disappears off
  -- the right edge (virt_lines can't scroll horizontally). Runs after the
  -- MAX_LINES cap so wrapping doesn't eat into the line budget.
  local ui_opts = config.options.ui or {}
  if ui_opts.wrap_output ~= false then
    local wrap_width = output_text_width(bufnr)
    if wrap_width then
      local wrapped = {}
      for _, vl in ipairs(virt_lines) do
        for _, line in ipairs(wrap_virt_line(vl, wrap_width)) do
          table.insert(wrapped, line)
        end
      end
      virt_lines = wrapped
    end
  end

  -- Attach at end_row so the output moves with the cell as it grows.
  -- right_gravity = false (not the default true), for two independently
  -- verified reasons (plan-refinement F2.1):
  --   1. With the default right_gravity = true, a `gcc`-style delete+insert
  --      of the cell's exact last line rides the mark onto the next cell's
  --      start row, so the output renders after the next cell's top line
  --      instead of after this cell.
  --   2. ns_border's bottom-border mark shares this exact anchor
  --      (cell.end_row, 0) and defaults to right_gravity = true. Verified
  --      empirically (nvim_buf_get_extmarks with ns_id = -1, cross-checked
  --      against actual screen output via :TOhtml): at the *same* (row,
  --      col), a right_gravity = false mark always sorts — and renders —
  --      before a right_gravity = true one, regardless of which was
  --      created or recreated more recently. So this isn't just a "pins
  --      the gcc case" fix — it's what makes the output mark deterministically
  --      render before (inside the cell, above) the border's bottom line
  --      instead of flip-flopping with it.
  vim.api.nvim_buf_set_extmark(bufnr, hl.ns_output, cell.end_row, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
    right_gravity = false,
    priority = 90,
  })

  restore_toplines(saved_toplines)
end

-- Render every cell that's actually showing something (skips hidden-output
-- cells and cells that have never run and have nothing to show). Shared by
-- init.lua's debounced WinResized/refresh_after_mutation redraw and
-- buffer.lua's unthrottled fallback (tests, which build notebooks without
-- the full attach path) — same predicate, same loop, one place to fix.
function M.render_all(bufnr, nb, filepath)
  for _, cell in ipairs(nb.cells) do
    if not cell._output_hidden
        and (cell.output or cell.console or cell._has_run) then
      M.render(bufnr, cell, filepath)
    end
  end
end

-- Clear output for all cells.
function M.clear_all(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, hl.ns_output, 0, -1)
  -- Tear down every inline-image placement in this buffer — they live in the
  -- backend's own namespace, so the clear above doesn't touch them.
  image.clear_for_cell(bufnr)
  -- Drop the entire widget registry for this buffer so stale entries don't
  -- survive a kernel restart / output clear.
  for k, _ in pairs(widgets._by_cell) do
    if k:sub(1, #tostring(bufnr) + 1) == bufnr .. ":" then
      widgets._by_cell[k] = nil
    end
  end
end

-- Handle an incoming cell-op WebSocket message.
-- Updates the cell's status and output, then re-renders.
function M.handle_cell_op(bufnr, nb, msg)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local cell_id = msg.cell_id
  if not cell_id then return end

  -- Find the cell by its server-assigned ID (nb.cell_by_id) or by scanning
  local cell = nb.cell_by_id[cell_id]
  if log.enabled() then
    log.write("cell-op", {
      cell_id = cell_id,
      known = cell ~= nil,
      status = msg.status,
      out_mime = msg.output and msg.output.mimetype,
    })
  end
  if not cell then
    -- Unknown cell ID means our ID mapping diverged from the kernel's (a
    -- reload re-keyed cells and one didn't reconcile). The cell-op we just
    -- got — the output, or the idle status that clears a stuck "queued" —
    -- would otherwise be dropped. Self-heal by reconnecting our kiosk WS:
    -- marimo replays kernel-ready (re-keys the map by code) and re-emits the
    -- existing outputs, so this op comes back under an id we now know.
    -- Warn once per id; debounce the resync so a burst triggers one, not many.
    -- Marks here are cleared by ws_handlers.rekey_cells_from_server on any
    -- successful re-key (plan-refinement F5.4) — a reconcile means the old
    -- "unknown" knowledge is stale, and leaving it would both grow this
    -- table unbounded over a session and permanently block a future id from
    -- ever re-triggering a resync.
    nb._unknown_cell_ids = nb._unknown_cell_ids or {}
    if not nb._unknown_cell_ids[cell_id] then
      nb._unknown_cell_ids[cell_id] = true
      local known = {}
      for id, _ in pairs(nb.cell_by_id) do table.insert(known, id) end
      if log.enabled() then
        log.write("cell-op:DROP", { cell_id = cell_id, known_ids = known })
      end
      utils.warn(
        "cell-op for unknown cell '" .. cell_id
          .. "' — resyncing. Known: " .. table.concat(known, ", ")
      )
    end
    local now = vim.uv.hrtime() / 1e6
    if nb.filepath and (not nb._resync_at or (now - nb._resync_at) > 3000) then
      nb._resync_at = now
      vim.schedule(function()
        local dispatched = server.resync_ws(nb.filepath)
        if log.enabled() then
          log.write("resync", { dispatched = dispatched, filepath = nb.filepath })
        end
      end)
    end
    return
  end

  -- Update status. Mark the cell as having been executed once we see it
  -- finish (idle) or fail (error) — this is what gates the "✓ ran" indicator.
  --
  -- Widget overrides are NOT cleared on any cell-op. Empirically marimo
  -- broadcasts cell-op with status transitions (queued/running/idle) on
  -- the slider's own cell after set_ui_element_value succeeds, even
  -- though the cell isn't being re-executed — every previous heuristic
  -- (clear-on-fresh-output, clear-on-status-transition) ended up tripping
  -- on those echoes and snapping the thumb back to the parsed
  -- data-initial-value. Now overrides persist for the lifetime of the
  -- cell; the user clears them explicitly by re-running the cell
  -- (actions.run_cell_at_cursor) or by `:MarimoResetWidgets`.
  if msg.status then
    cell.status = msg.status
    -- A real kernel status supersedes the optimistic ⟳ widget_picker.commit
    -- paints while a set_ui_element_value POST is in flight; once this flag
    -- is off, the POST callback knows not to roll the status back.
    cell._optimistic_status = nil
    if msg.status == "idle" or msg.status == "error" then
      cell._has_run = true
    end
  end

  if msg.output then
    cell.output = msg.output
  end

  -- Accumulate console output. The shape varies:
  --   * `[]`                       → clear console
  --   * `[CellOutput, ...]`        → replace console list
  --   * `CellOutput` (object)      → append to console list
  --
  -- The first two have to be distinguished from the third by structure, not
  -- by `#`: a single CellOutput is a table with named keys (channel/mimetype/
  -- data), so `#msg.console == 0` is true for it too. `next(t) == nil` is
  -- the only reliable "truly empty table" check.
  if msg.console then
    if type(msg.console) == "table" then
      if next(msg.console) == nil then
        cell.console = nil
      elseif msg.console[1] and msg.console[1].channel then
        cell.console = msg.console
      elseif msg.console.channel then
        cell.console = cell.console or {}
        table.insert(cell.console, msg.console)
        -- Bound the stored list (see MAX_CONSOLE_ENTRIES comment above) —
        -- drop the oldest entries first so the most recent output (what a
        -- user watching stdout actually wants) survives.
        while #cell.console > MAX_CONSOLE_ENTRIES do
          table.remove(cell.console, 1)
        end
      end
    end
  end

  -- Re-render output for this cell
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.render(bufnr, cell, nb.filepath)
    end
  end)
end

return M

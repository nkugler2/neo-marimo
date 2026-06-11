-- Cell output rendering via extmark virtual lines.
-- Handles the cell-op messages from the marimo WebSocket.

local hl = require("neo-marimo.highlights")
local markdown = require("neo-marimo.markdown")
local image = require("neo-marimo.image")
local widgets = require("neo-marimo.widgets")
local dataframe = require("neo-marimo.dataframe")
local server = require("neo-marimo.server")
local tree_render = require("neo-marimo.tree_render")

local M = {}

-- Maximum output lines to show per cell before truncating.
local MAX_LINES = 30

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
-- side-effect. tree_render writes `image_drawn` and `skip_cap` back into it.
local _render_ctx = {
  bufnr = nil, cell_id = nil, row = nil, filepath = nil,
  image_drawn = false, skip_cap = false,
}

-- ── Renderer registry ──────────────────────────────────────────────────────
--
-- Each renderer takes (data, opts) and returns a list of virt_line chunk lists
-- (i.e. a list where each element is itself a list of {text, hl_group} pairs).
-- `data` is the payload from the CellOutput; `opts` is reserved for future
-- per-call options (e.g. window width). Phase 8 plugs image/widget renderers
-- in via M.register_renderer at setup time.

M.renderers = {}

-- Lookup order for prefix matches like `image/png` → `image/*`. We try the
-- exact mimetype first, then any registered prefix patterns in order.
M.renderer_patterns = {}

-- Register a renderer for an exact mimetype (e.g. "text/plain") or a pattern
-- ending in `/*` (e.g. "image/*"). Patterns are matched after exact mimetypes.
function M.register_renderer(mime, fn)
  if mime:sub(-2) == "/*" then
    -- strip the trailing "*", keep the "/" so "image/*" stores prefix "image/"
    table.insert(M.renderer_patterns, { prefix = mime:sub(1, -2), fn = fn })
  else
    M.renderers[mime] = fn
  end
end

local function lookup_renderer(mime)
  if M.renderers[mime] then return M.renderers[mime] end
  for _, p in ipairs(M.renderer_patterns) do
    if mime:sub(1, #p.prefix) == p.prefix then
      return p.fn
    end
  end
  return nil
end

-- ── Built-in renderers ─────────────────────────────────────────────────────

local function render_text_plain(data)
  if type(data) ~= "string" then
    data = tostring(data)
  end
  local lines = {}
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, { { "  " .. line, "MarimoOutputText" } })
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
      _render_ctx.image_drawn = true
      return image.render_base64(_render_ctx.bufnr, _render_ctx.row or 0, mime, b64, _render_ctx.cell_id)
    end
  end

  -- Inline <svg> markup (mo.Html(svg), mo.md with embedded SVG). Rasterise it
  -- through the image path rather than stripping the tags to nothing.
  local svg = image.extract_inline_svg(data)
  if svg then
    _render_ctx.image_drawn = true
    return image.render_at(_render_ctx.bufnr, _render_ctx.row or 0,
      "image/svg+xml", svg, _render_ctx.cell_id)
  end

  -- Server-hosted virtual-file image (mo.image, etc.): the <img src> points at
  -- "./@file/…" and the bytes live on the marimo server. Fetch and render them.
  local vf = image.extract_virtual_file(data)
  if vf and _render_ctx.filepath then
    _render_ctx.image_drawn = true
    local filepath = _render_ctx.filepath
    return image.render_url(_render_ctx.bufnr, _render_ctx.row or 0, vf, _render_ctx.cell_id,
      function(dest) return server.fetch_virtual_file(filepath, vf, dest) end)
  end

  -- Fallback: strip remaining tags. Surface SVG/<img> as a placeholder so
  -- the user knows there's content their terminal couldn't render.
  local lines = {}
  local has_image = data:find("<img[^%w]") or data:find("<svg[^%w]")
  if has_image then
    table.insert(lines, { { "  [image — install image.nvim or open in browser]", "Comment" } })
  end
  local stripped = data:gsub("<[^>]+>", "")
    :gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " ")
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
  _render_ctx.image_drawn = true
  return image.render_base64(_render_ctx.bufnr, _render_ctx.row or 0,
    mime or "image/png", tostring(data or ""), _render_ctx.cell_id)
end

local function render_svg(data)
  -- SVG arrives as XML text. Most terminal image protocols can't render
  -- SVG directly; image.nvim can with the right backend, snacks.image can
  -- too. We pass the raw bytes through the image module which will write
  -- the SVG to a file — backends that can rasterize it will, the rest will
  -- show the file-path placeholder.
  if type(data) ~= "string" then return {} end
  _render_ctx.image_drawn = true
  return image.render_at(_render_ctx.bufnr, _render_ctx.row or 0,
    "image/svg+xml", data, _render_ctx.cell_id)
end

local function render_markdown_mime(data)
  -- markdown.render auto-detects HTML wrappers (`<span class="markdown
  -- prose">`) and unwraps them, then renders. Routing through `render`
  -- rather than `render_markdown_source` is what makes mimetype
  -- text/markdown work when marimo serializes mo.md() output as
  -- pre-rendered HTML wearing a text/markdown sticker — observed in
  -- marimo ≥ 0.19.
  return require("neo-marimo.markdown").render(data)
end

local function render_marimo_mime(data)
  -- application/vnd.marimo+mime is a JSON envelope: {mimetype, data}.
  -- Route the inner payload through the standard lookup so e.g. a widget
  -- wrapped in a mime envelope reaches the widget renderer.
  if type(data) == "table" and data.mimetype then
    local renderer = M._lookup_renderer(data.mimetype)
    if renderer then return renderer(data.data, {}) end
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

-- Register built-ins. mo.md() emits text/html with a `<span class="markdown
-- prose ...">` wrapper; render_html detects that shape and forwards to the
-- markdown renderer (Phase 8.1). Raw text/markdown payloads (rare but
-- possible) route straight to render_markdown_mime.
M.register_renderer("text/plain", render_text_plain)
M.register_renderer("text/html", render_html)
M.register_renderer("text/markdown", render_markdown_mime)
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
    return renderer(data, {}, mimetype)
  end

  -- text/plain or unknown mime: unwrap an embedded image if present, else
  -- fall back to dumping as text.
  local img_mime, img_data = extract_embedded_image(data)
  if img_mime and img_data then
    _render_ctx.image_drawn = true
    return image.render_base64(_render_ctx.bufnr, _render_ctx.row or 0, img_mime, img_data, _render_ctx.cell_id)
  end

  if type(data) == "string" then
    return render_text_plain(data)
  end
  return { { { "  [" .. mimetype .. "]", "Comment" } } }
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

-- ── Public API ──────────────────────────────────────────────────────────────

-- Render (or clear) the output for a cell.
-- `cell` must have `.end_row` set correctly. `filepath` (optional) is the
-- notebook path, used to fetch server-hosted virtual-file images.
function M.render(bufnr, cell, filepath)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

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
        table.insert(virt_lines, { { "  … (output truncated, open in browser for full view)", "Comment" } })
        break
      end
      table.insert(virt_lines, vl)
      shown = shown + 1
    end
  end

  -- Console output (stdout/stderr printed during execution)
  if cell.console and #cell.console > 0 then
    for _, cout in ipairs(cell.console) do
      if cout.data and cout.data ~= "" then
        local console_lines = render_text_plain(cout.data)
        for _, vl in ipairs(console_lines) do
          table.insert(virt_lines, vl)
        end
      end
    end
  end

  -- No image this pass → drop any placement this cell left behind earlier.
  if not _render_ctx.image_drawn then
    image.clear_for_cell(bufnr, cell.id)
  end

  if #virt_lines == 0 then return end

  -- Attach at end_row so the output moves with the cell as it grows
  vim.api.nvim_buf_set_extmark(bufnr, hl.ns_output, cell.end_row, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
    priority = 90,
  })
end

-- Clear output for a specific cell.
function M.clear(bufnr, cell)
  cell.output = nil
  cell.console = nil
  cell.status = "idle"
  widgets.clear_for_cell(bufnr, cell.id)
  M.render(bufnr, cell)
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
  if not cell then
    -- Unknown cell IDs almost always mean our ID mapping is out of sync with
    -- the server's (kernel-ready didn't re-key, or marimo registered cells
    -- under different IDs at /run time). Warn once per ID so the user can
    -- see what's happening instead of just watching "queued" forever.
    nb._unknown_cell_ids = nb._unknown_cell_ids or {}
    if not nb._unknown_cell_ids[cell_id] then
      nb._unknown_cell_ids[cell_id] = true
      local known = {}
      for id, _ in pairs(nb.cell_by_id) do table.insert(known, id) end
      vim.notify(
        "[neo-marimo] cell-op for unknown cell '" .. cell_id
          .. "'. Known: " .. table.concat(known, ", "),
        vim.log.levels.WARN
      )
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

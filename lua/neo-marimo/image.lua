-- Phase 8.2 — image rendering for cell output.
--
-- Marimo emits images in two shapes:
--   1. mimetype = "image/png" | "image/jpeg" | "image/svg+xml", data = base64
--   2. mimetype = "text/html", data contains <img src="data:image/png;base64,…">
--      (matplotlib goes through this path)
--
-- Strategy: write the decoded bytes to a temp file under
-- `stdpath("cache")/neo-marimo/images/`, then either delegate to an installed
-- image rendering plugin (image.nvim, snacks.image) or fall back to a
-- placeholder virt_line that names the file path so the user can :Inspect it
-- with their tool of choice.
--
-- Direct emission of kitty graphics escape sequences from inside a
-- nvim_buf_set_extmark virt_line isn't supported by core (virt_lines are
-- character cells, not pixel data). The plugin path is the only realistic
-- way to get pixels onscreen without a fork of nvim — when it isn't present
-- we degrade gracefully rather than fail.

local M = {}

local log = require("neo-marimo.log")

-- ── temp-file plumbing ────────────────────────────────────────────────────

local function image_dir()
  local d = vim.fn.stdpath("cache") .. "/neo-marimo/images"
  vim.fn.mkdir(d, "p")
  return d
end

-- Stable extension by mimetype so file-type sniffers (e.g. file(1)) match.
local function ext_for_mime(mime)
  if mime == "image/png" then return "png" end
  if mime == "image/jpeg" or mime == "image/jpg" then return "jpg" end
  if mime == "image/gif" then return "gif" end
  if mime == "image/webp" then return "webp" end
  if mime == "image/svg+xml" then return "svg" end
  return "bin"
end

-- Inverse of ext_for_mime: best-effort mimetype from a file extension, used
-- when we render a downloaded virtual file whose mimetype isn't otherwise known.
local function mime_for_ext(ext)
  ext = (ext or ""):lower()
  if ext == "png" then return "image/png" end
  if ext == "jpg" or ext == "jpeg" then return "image/jpeg" end
  if ext == "gif" then return "image/gif" end
  if ext == "webp" then return "image/webp" end
  if ext == "svg" then return "image/svg+xml" end
  return "image/" .. (ext ~= "" and ext or "png")
end

-- Pick a deterministic filename for a given (mime, data) pair so repeated
-- renders of the same image don't fill the temp dir. We hash the base64 prefix
-- because hashing the full payload for every render is wasteful, and the
-- prefix collides only on actually-identical images.
local function sample_hash(s)
  local sample = #s > 4096 and (s:sub(1, 2048) .. s:sub(-2048)) or s
  return vim.fn.sha256(sample):sub(1, 16)
end

-- Decode base64 (with or without standard padding/whitespace) using
-- vim.base64.decode (nvim ≥ 0.11). Returns the bytes or nil on error.
local function b64_decode(s)
  s = s:gsub("%s", "")
  -- Pad to 4-char boundary if needed (some HTML strips the trailing =).
  local pad = (4 - (#s % 4)) % 4
  if pad > 0 then s = s .. string.rep("=", pad) end
  local ok, decoded = pcall(vim.base64.decode, s)
  if not ok then return nil end
  return decoded
end

-- Sniff an image's real mimetype from its leading magic bytes. marimo names
-- every image virtual file ".png" regardless of the true format, and snacks'
-- PNG fast-path keys off the file extension — so a JPEG in a .png file gets
-- sent to the terminal as broken PNG and silently fails to draw. We read the
-- header ourselves to give the file an honest extension. Returns a mimetype
-- string or nil if unrecognised.
local function sniff_image_mime(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local head = f:read(16) or ""
  f:close()
  local b = { head:byte(1, 16) }
  if b[1] == 0xFF and b[2] == 0xD8 and b[3] == 0xFF then return "image/jpeg" end
  if b[1] == 0x89 and b[2] == 0x50 and b[3] == 0x4E and b[4] == 0x47 then return "image/png" end
  if b[1] == 0x47 and b[2] == 0x49 and b[3] == 0x46 then return "image/gif" end -- GIF
  if b[1] == 0x52 and b[2] == 0x49 and b[3] == 0x46 and b[4] == 0x46
     and b[9] == 0x57 and b[10] == 0x45 and b[11] == 0x42 and b[12] == 0x50 then
    return "image/webp" -- RIFF????WEBP
  end
  local txt = head:match("^%s*(.-)$") or head
  if txt:find("<svg", 1, true) or txt:find("<?xml", 1, true) then return "image/svg+xml" end
  return nil
end

-- Persist the decoded bytes to disk and return the path.
local function write_temp(mime, bytes)
  local hash = sample_hash(bytes)
  local path = image_dir() .. "/" .. hash .. "." .. ext_for_mime(mime)
  if vim.uv.fs_stat(path) then return path end

  local f, err = io.open(path, "wb")
  if not f then
    vim.notify("[neo-marimo] image write failed: " .. tostring(err),
      vim.log.levels.WARN)
    return nil
  end
  f:write(bytes)
  f:close()
  return path
end

-- ── renderer detection ────────────────────────────────────────────────────

-- Detect at first call which inline-image plugin is available. Cached for
-- the rest of the session so we don't re-probe on every cell render. Order
-- mirrors the plan: image.nvim first (most popular), snacks.image second.
local _backend_cache = nil

local function pick_backend()
  if _backend_cache ~= nil then return _backend_cache end

  local ok_image = pcall(require, "image")
  if ok_image then
    _backend_cache = "image.nvim"
    return _backend_cache
  end

  -- Only accept snacks if its image *placement* API is actually present.
  -- A bare `require("snacks").image` succeeds whenever snacks is installed,
  -- even when the image feature isn't enabled — which would falsely route us
  -- down a backend that can't draw anything.
  local ok_snacks = pcall(function()
    local s = require("snacks")
    assert(type(s.image) == "table"
      and type(s.image.placement) == "table"
      and type(s.image.placement.new) == "function")
  end)
  if ok_snacks then
    _backend_cache = "snacks.image"
    return _backend_cache
  end

  _backend_cache = false  -- explicit false so the nil check above re-fires
  return _backend_cache
end

-- ── placement registry ────────────────────────────────────────────────────
--
-- Inline-image backends (snacks.image, image.nvim) draw via their own
-- extmarks/placements, which live outside our ns_output namespace. If we just
-- create a fresh placement on every M.render (and a cell re-renders on every
-- queued/running/idle cell-op), they stack — the user sees a row of duplicate
-- image glyphs. We key each placement by its owning cell and tear the previous
-- one down before drawing the next, mirroring widgets.clear_for_cell.
--
-- `_placements[bufnr][key]` holds `{ path = <temp file>, close = <fn> }`. The
-- `close` fn tears down whatever the backend created (stays backend-agnostic);
-- `path` lets us recognise "this cell already shows exactly this image" and
-- skip a needless close/recreate, which would otherwise flicker.
local _placements = {}

local function register_placement(bufnr, key, path, closer)
  if not key then return end
  _placements[bufnr] = _placements[bufnr] or {}
  _placements[bufnr][key] = { path = path, close = closer }
end

-- Move placement registry entries to follow a cell re-key, without closing
-- or recreating them — the underlying image is still valid, only the key
-- that finds it changed. `moves` is `{ [old_cell_id] = new_cell_id }` for
-- cells whose id actually changed (see ws_handlers.lua's rekey_by_position /
-- rekey_by_code). Without this, overwriting cell.id in place orphans the
-- entry under its old key: the next render looks up the new id, finds
-- nothing to close, and draws a *second* backend placement on top of the
-- stale one, which keeps painting until session end
-- (docs/plan-refinement.md F2.6).
--
-- Two passes, mirroring rebuild_index's own comment: collect every moved
-- entry against the OLD table state first, then write them under their new
-- keys, so a chain/swap of ids (one cell's new id equal to another cell's
-- old id) can't drop or double an entry.
function M.migrate_keys(bufnr, moves)
  local buf_pl = _placements[bufnr]
  if not buf_pl or not moves or next(moves) == nil then return end
  local snapshot = {}
  for old_key, new_key in pairs(moves) do
    local entry = buf_pl[old_key]
    if entry then
      snapshot[new_key] = entry
      buf_pl[old_key] = nil
    end
  end
  for new_key, entry in pairs(snapshot) do
    buf_pl[new_key] = entry
  end
end

-- Close and forget the placement(s) for a buffer. With `key`, only that cell's
-- placement; without, every placement in the buffer.
function M.clear_for_cell(bufnr, key)
  local buf_pl = _placements[bufnr]
  if not buf_pl then return end
  if key ~= nil then
    local entry = buf_pl[key]
    if entry then
      -- Log close *failures* too: a throwing backend close is swallowed by
      -- the pcall (rendering must go on), but the terminal graphic it was
      -- supposed to delete stays painted — the one leak the registry can't
      -- see. Surfacing it in :MarimoWsDebug is the only trace it leaves.
      local ok = pcall(entry.close)
      if log.enabled() then
        log.write("img:clear", { key = key, close_ok = ok })
      end
    end
    buf_pl[key] = nil
  else
    for k, entry in pairs(buf_pl) do
      local ok = pcall(entry.close)
      if log.enabled() and not ok then
        log.write("img:clear", { key = k, close_ok = false })
      end
    end
    _placements[bufnr] = nil
  end
end

-- Close every placement in every buffer. Used by the VimLeavePre sweep and
-- BufWipeout cleanup: kitty graphics painted through tmux passthrough
-- outlive the nvim process (the terminal keeps the pixels; tmux never
-- tracks or repaints them), so an exit that doesn't explicitly delete
-- placements strands them as fossils the next session shows as a stale
-- duplicate graph (docs/plan-refinement.md F2.7). Snapshot the buffer keys
-- before closing — clear_for_cell(bufnr) (no key) nils out
-- _placements[bufnr], which would corrupt a live `pairs` iteration.
function M.clear_all()
  local bufnrs = {}
  for bufnr in pairs(_placements) do
    table.insert(bufnrs, bufnr)
  end
  for _, bufnr in ipairs(bufnrs) do
    M.clear_for_cell(bufnr)
  end
end

-- ── terminal sweep (F2.7) ────────────────────────────────────────────────
--
-- Everything above manages placements *this session* created. It can't see
-- placements a previous (crashed, force-quit, or pre-F2.7) session left
-- behind: inside tmux those live entirely in the terminal's kitty-graphics
-- state, which tmux passthrough never mirrors back to us. The only way to
-- clear that inherited state is to ask the terminal to delete everything.

-- Bare kitty "delete all images" escape. `a=d` selects the delete action;
-- `d=A` (as opposed to plain `d`, which only hides placements) also frees
-- the terminal's stored image data, so it can't reappear on a later resize
-- or repaint.
local KITTY_DELETE_ALL = "\27_Ga=d,d=A\27\\"

-- Build the escape sequence to emit, without emitting it — kept separate
-- from sweep_terminal so tests can assert on both the bare and
-- tmux-wrapped forms without a real terminal attached. tmux passthrough
-- requires wrapping the whole sequence in `\27Ptmux;...\27\\` with every
-- literal ESC inside doubled, or tmux parses (and swallows) the inner
-- escape itself instead of forwarding it to the terminal.
function M._sweep_sequence(in_tmux)
  if not in_tmux then return KITTY_DELETE_ALL end
  local doubled = KITTY_DELETE_ALL:gsub("\27", "\27\27")
  return "\27Ptmux;" .. doubled .. "\27\\"
end

-- Overridable emit seam. Production writes straight to the terminal via
-- the stderr channel — the way inline-image plugins send control
-- sequences without the TUI swallowing them as keystrokes; io.stdout would
-- fight nvim's own screen writes. pcall'd as defense against embed/remote
-- configurations where the stderr channel may reject writes (plain
-- --headless accepts them — verified — so this is belt-and-braces, not a
-- headless requirement). Tests replace this with a capturing stub so the
-- gating logic can be asserted without a terminal.
function M._emit(seq)
  pcall(vim.api.nvim_chan_send, vim.v.stderr, seq)
end

-- Emit a kitty delete-all-images escape to the terminal. Two callers:
--   * the once-per-session attach sweep (force = false), gated to tmux
--     (outside tmux the terminal clears its own state on exit fine, and
--     nuking other apps' images would be an unwelcome surprise) — see
--     init.lua's attach-time call for the "first attach only" guard;
--   * :MarimoImageRepaint (force = true), which also runs bare so it works
--     as a recovery command even without tmux in the picture.
-- Skipped either way when no image backend is detected: if nothing could
-- have drawn a kitty placement, there's nothing to clear.
function M.sweep_terminal(force)
  if not pick_backend() then return end
  local in_tmux = vim.env.TMUX ~= nil and vim.env.TMUX ~= ""
  if not in_tmux and not force then return end
  M._emit(M._sweep_sequence(in_tmux))
end

-- ── public API ────────────────────────────────────────────────────────────

-- Draw an image that already lives on disk at `path`, using whatever backend
-- is available and registering the placement under `key`. Shared by render_at
-- (bytes written to a temp file) and render_url (bytes downloaded from the
-- server). `row` is 0-indexed. Returns virt_line chunks (empty when the
-- backend draws the image itself and needs no placeholder).
local function render_path(bufnr, row, mime, path, key)
  -- If this cell already shows exactly this file, leave the live placement
  -- alone (paths are content- or URL-hashed, so an unchanged image yields the
  -- same path). Avoids the close/recreate flicker on repeated status renders.
  local existing = key and _placements[bufnr] and _placements[bufnr][key]
  if existing and existing.path == path then return {} end

  -- Otherwise drop any prior placement this cell owns before drawing the new.
  M.clear_for_cell(bufnr, key)

  local backend = pick_backend()
  if log.enabled() then
    -- row + path make placement leaks diagnosable from the log alone: two
    -- live versions of one plot show up as renders under different keys (or
    -- rows) whose earlier entry never got a matching img:clear (F2.6 repro).
    log.write("img:render_path", { backend = backend, mime = mime, key = key, row = row, path = path })
  end

  if backend == "image.nvim" then
    local ok, image = pcall(require, "image")
    if ok then
      local ok_create, img = pcall(image.from_file, path, {
        buffer = bufnr,
        with_virtual_padding = true,
        x = 2,
        y = row + 1,
      })
      if log.enabled() then
        log.write("img:image.nvim", { ok_create = ok_create, has_img = img ~= nil })
      end
      if ok_create and img then
        pcall(function() img:render() end)
        register_placement(bufnr, key, path, function()
          pcall(function() img:clear() end)
        end)
        -- image.nvim handles its own placeholder rows; return an empty
        -- list so we don't double-up with our own.
        return {}
      end
    end
  elseif backend == "snacks.image" then
    local ok, snacks = pcall(require, "snacks")
    if ok and snacks.image and snacks.image.placement then
      -- Signature is `placement.new(buf, src, opts)` where `src` is a *string*
      -- path (snacks asserts `type(src) == "string"`). `inline = true` draws
      -- the image into the buffer via virtual-padding extmarks (the mode
      -- snacks itself uses for markdown images); `pos` is (1,0)-indexed.
      -- pcall returns ok_create=true whenever the call doesn't *raise* — but
      -- placement.new can run and still return nil, so require a real object
      -- before we suppress the text fallback.
      local ok_create, placement = pcall(snacks.image.placement.new, bufnr, path, {
        pos = { row + 1, 0 },
        inline = true,
      })
      if log.enabled() then
        log.write("img:snacks", {
          ok_create = ok_create,
          placement_nil = placement == nil,
          err = (not ok_create) and tostring(placement) or nil,
        })
      end
      if ok_create and placement ~= nil then
        register_placement(bufnr, key, path, function() placement:close() end)
        return {}
      end
      if not ok_create then
        vim.notify("[neo-marimo] snacks.image failed: " .. tostring(placement),
          vim.log.levels.WARN)
      end
    end
  end

  -- Fallback: announce the file so the user can open it externally.
  if log.enabled() then log.write("img:fallback", { backend = backend, path = path }) end
  local short = vim.fn.fnamemodify(path, ":~")
  return {
    { { "  [image — ", "Comment" }, { mime, "MarimoWidgetLabel" }, { "]", "Comment" } },
    { { "  saved to ", "Comment" }, { short, "MarimoMarkdownLink" } },
    { { "  install image.nvim or snacks.image for inline display", "Comment" } },
  }
end

-- Render raw image bytes at (bufnr, row). Writes them to a content-hashed temp
-- file (so identical images dedupe), then draws. `key` (optional) ties the
-- placement to a cell so the next render of that cell replaces rather than
-- stacks. Returns virt_line chunks (empty when the backend draws the image).
function M.render_at(bufnr, row, mime, bytes, key)
  if not bytes or bytes == "" then return {} end

  local path = write_temp(mime, bytes)
  if not path then
    return { { { "  [image — decode failed]", "MarimoOutputError" } } }
  end
  return render_path(bufnr, row, mime, path, key)
end

-- Render a server-hosted image referenced by `vf_path` (a marimo virtual-file
-- reference such as "./@file/123-name.jpeg"). The actual download is performed
-- by `fetch(dest_path) -> bool`, injected by the caller so this module stays
-- free of server/auth coupling. The download is cached by a hash of vf_path,
-- so repeated renders of the same output reuse the file and its placement.
function M.render_url(bufnr, row, vf_path, key, fetch)
  if type(vf_path) ~= "string" or vf_path == "" then return {} end

  local stem = image_dir() .. "/vf_" .. sample_hash(vf_path)

  -- Reuse a previously downloaded + correctly-named file if one exists, so
  -- repeated renders neither re-download nor re-sniff.
  for _, ext in ipairs({ "png", "jpg", "gif", "webp", "svg" }) do
    local p = stem .. "." .. ext
    if vim.uv.fs_stat(p) then
      return render_path(bufnr, row, mime_for_ext(ext), p, key)
    end
  end

  -- Download to a neutral name, then sniff the *real* format (the vf_path's
  -- own extension is unreliable — marimo labels image virtual files .png).
  local raw = stem .. ".raw"
  if not fetch(raw) then
    return { { { "  [image — fetch failed]", "MarimoOutputError" } } }
  end
  local mime = sniff_image_mime(raw) or "image/png"
  local path = stem .. "." .. ext_for_mime(mime)
  if not vim.uv.fs_rename(raw, path) then path = raw end
  return render_path(bufnr, row, mime, path, key)
end

-- Decode a base64 payload and render it. `data` may include or omit
-- whitespace; `mime` is the MIME type of the encoded payload. `key` (optional)
-- ties the placement to a cell so re-renders replace rather than stack.
function M.render_base64(bufnr, row, mime, data, key)
  local bytes = b64_decode(data)
  if not bytes then
    return { { { "  [image — invalid base64]", "MarimoOutputError" } } }
  end
  return M.render_at(bufnr, row, mime, bytes, key)
end

-- Extract a data:image/...;base64,... URI from a string. Returns
-- (mime, base64_data) or nil if no match.
function M.extract_data_uri(html)
  if type(html) ~= "string" then return nil end
  local mime, data = html:match('data:(image/[%w%+%-%.]+);base64,([A-Za-z0-9%+/=\n\r%s]+)')
  if not mime or not data then return nil end
  -- Strip trailing junk past the base64 alphabet (closing quote, > etc).
  data = data:match("^[A-Za-z0-9%+/=\n\r%s]+") or data
  return mime, data
end

-- True if the html payload contains an embedded data URI we can extract.
function M.has_embedded_image(html)
  return M.extract_data_uri(html) ~= nil
end

-- Extract an inline <svg>…</svg> block from an HTML payload (e.g. mo.Html(svg)
-- or mo.md with embedded SVG). Returns the SVG markup string or nil. Lua `.`
-- spans newlines, so multi-line SVG is matched fine.
function M.extract_inline_svg(html)
  if type(html) ~= "string" then return nil end
  return html:match("<svg.-</svg>")
end

-- Extract a marimo virtual-file image reference (an <img src> pointing at
-- "./@file/…") from an HTML payload. mo.image and friends store the bytes on
-- the server and reference them by URL rather than inlining them. Returns the
-- reference string (e.g. "./@file/123-name.jpeg") or nil.
function M.extract_virtual_file(html)
  if type(html) ~= "string" then return nil end
  -- marimo's HTML builder quotes every attribute with single quotes
  -- (`_join_params` → `k='v'`), so match either quote style to be safe.
  for src in html:gmatch("<img[^>]-src=['\"]([^'\"]+)['\"]") do
    if src:find("@file", 1, true) then return src end
  end
  return nil
end

-- Reset the cached backend probe. Used by tests or by users who install
-- image.nvim mid-session and want neo-marimo to pick it up without restart.
function M.reset_backend()
  _backend_cache = nil
end

-- Name of the detected inline-image backend ("image.nvim" or
-- "snacks.image"), or nil when none is usable. Used by :checkhealth.
function M.backend()
  return pick_backend() or nil
end

-- Expose for callers that need it (e.g. tests).
M._b64_decode = b64_decode

-- Test seam: seed the placement registry directly, bypassing render_path's
-- backend dispatch (image.nvim/snacks.image aren't available in the headless
-- test env, so a real M.render_at would always fall through to the
-- no-placement text fallback). Lets specs assert on migrate_keys /
-- clear_for_cell behaviour with a plain close-spy closure.
function M._register_for_test(bufnr, key, path, closer)
  register_placement(bufnr, key, path, closer)
end

return M

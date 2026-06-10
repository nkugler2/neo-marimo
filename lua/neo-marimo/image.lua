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

-- ── public API ────────────────────────────────────────────────────────────

-- Render an inline image at the given (bufnr, row) using whatever backend is
-- available. Falls back to writing the file and returning virt_lines that
-- name it. `row` is 0-indexed (the buffer row the image should attach to).
--
-- Returns a list of virt_line chunks (possibly empty when the backend draws
-- the image itself and doesn't need a placeholder).
function M.render_at(bufnr, row, mime, bytes)
  if not bytes or bytes == "" then return {} end

  local path = write_temp(mime, bytes)
  if not path then
    return { { { "  [image — decode failed]", "MarimoOutputError" } } }
  end

  local backend = pick_backend()

  if backend == "image.nvim" then
    local ok, image = pcall(require, "image")
    if ok then
      local ok_create, img = pcall(image.from_file, path, {
        buffer = bufnr,
        with_virtual_padding = true,
        x = 2,
        y = row + 1,
      })
      if ok_create and img then
        pcall(function() img:render() end)
        -- image.nvim handles its own placeholder rows; return an empty
        -- list so we don't double-up with our own.
        return {}
      end
    end
  elseif backend == "snacks.image" then
    local ok, snacks = pcall(require, "snacks")
    if ok and snacks.image and snacks.image.placement then
      -- pcall returns ok_create=true whenever the call doesn't *raise* — but
      -- placement.new can run and still return nil (no placement made). Only
      -- suppress the text fallback when a real placement comes back.
      local ok_create, placement = pcall(snacks.image.placement.new, bufnr,
        { src = path, pos = { row + 1, 0 } })
      if ok_create and placement ~= nil then return {} end
      if not ok_create then
        vim.notify("[neo-marimo] snacks.image failed: " .. tostring(placement),
          vim.log.levels.WARN)
      end
    end
  end

  -- Fallback: announce the file so the user can open it externally.
  local short = vim.fn.fnamemodify(path, ":~")
  return {
    { { "  [image — ", "Comment" }, { mime, "MarimoWidgetLabel" }, { "]", "Comment" } },
    { { "  saved to ", "Comment" }, { short, "MarimoMarkdownLink" } },
    { { "  install image.nvim or snacks.image for inline display", "Comment" } },
  }
end

-- Decode a base64 payload and render it. `data` may include or omit
-- whitespace; `mime` is the MIME type of the encoded payload.
function M.render_base64(bufnr, row, mime, data)
  local bytes = b64_decode(data)
  if not bytes then
    return { { { "  [image — invalid base64]", "MarimoOutputError" } } }
  end
  return M.render_at(bufnr, row, mime, bytes)
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

-- Reset the cached backend probe. Used by tests or by users who install
-- image.nvim mid-session and want neo-marimo to pick it up without restart.
function M.reset_backend()
  _backend_cache = nil
end

-- Expose for callers that need it (e.g. tests).
M._b64_decode = b64_decode

return M

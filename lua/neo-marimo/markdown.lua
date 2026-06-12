-- Phase 8.1 — markdown rendering for cell output.
--
-- Marimo's `mo.md(...)` produces an HTML payload wrapped in a `<span
-- class="markdown prose ...">` element. We unwrap that and convert the inner
-- HTML back into markdown source so it can be rendered with structured
-- highlights (headings, lists, code blocks, inline code, links).
--
-- The `render` entry point also accepts raw markdown — useful if marimo
-- ever switches to emitting `text/markdown` directly, and for any caller
-- that wants to highlight a known-markdown string.
--
-- ~150 LOC, no plugin deps.

local M = {}

-- ── HTML helpers ──────────────────────────────────────────────────────────

-- Single shared entity decoder (named + numeric refs) lives in html.lua.
local decode_entities = require("neo-marimo.html").decode_entities

-- True if the payload looks like marimo's HTML markdown wrapper, vs. an
-- arbitrary HTML blob that happens to contain markdown-ish text.
local function looks_like_marimo_md_html(html)
  if type(html) ~= "string" then return false end
  return html:find('<span class="markdown', 1, true) ~= nil
      or html:find('<div class="markdown', 1, true) ~= nil
      or html:find("<h%d") ~= nil  -- bare headings (cell return value)
      or html:find("<p[%s>]") ~= nil
end

-- Convert marimo's HTML markdown output back to markdown source. The
-- output of mo.md() is structured (block-level tags wrap inline content),
-- so a small set of pattern substitutions reproduces the original markup
-- well enough for our rendering pass.
local function html_to_md(html)
  -- Strip the outer markdown wrapper if present.
  html = html:gsub('<span class="markdown[^"]*"[^>]*>(.*)</span>%s*$', "%1")
  html = html:gsub('<div class="markdown[^"]*"[^>]*>(.*)</div>%s*$', "%1")

  -- Code blocks before generic <pre>/<code> to capture the language tag.
  html = html:gsub(
    '<pre[^>]*>%s*<code[^>]*class="language%-([^"]*)"[^>]*>(.-)</code>%s*</pre>',
    function(lang, code)
      return "\n```" .. lang .. "\n" .. decode_entities(code) .. "\n```\n"
    end
  )
  html = html:gsub(
    "<pre[^>]*>%s*<code[^>]*>(.-)</code>%s*</pre>",
    function(code) return "\n```\n" .. decode_entities(code) .. "\n```\n" end
  )
  html = html:gsub("<pre[^>]*>(.-)</pre>", function(code)
    return "\n```\n" .. decode_entities(code) .. "\n```\n"
  end)

  -- Block-level: headings, paragraphs, lists, blockquote, hr. Each rewrites
  -- to a single line so the line-based parser below picks it up cleanly.
  for level = 1, 6 do
    local h = "<h" .. level .. "[^>]*>(.-)</h" .. level .. ">"
    html = html:gsub(h, "\n" .. string.rep("#", level) .. " %1\n")
  end

  -- Blockquote: strip any surrounding <p>...</p> from the inner content
  -- first so we don't end up with a `> <p>…</p>` literal that the
  -- paragraph pass below can't fully clean up.
  html = html:gsub("<blockquote[^>]*>(.-)</blockquote>", function(content)
    content = content:gsub("<p[^>]*>(.-)</p>", "%1\n")
    local out = "\n"
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed ~= "" then out = out .. "> " .. trimmed .. "\n" end
    end
    return out
  end)

  html = html:gsub("<hr%s*/?>", "\n---\n")

  -- Ordered list: track the index inside the closure so 1., 2., 3. are
  -- preserved. Marimo doesn't always serialize the `start=` attribute,
  -- so resetting per-<ol> is the safe default.
  html = html:gsub("<ol[^>]*>(.-)</ol>", function(content)
    local n = 0
    local out = "\n"
    for item in content:gmatch("<li[^>]*>(.-)</li>") do
      n = n + 1
      out = out .. tostring(n) .. ". " .. item:gsub("^%s+", "") .. "\n"
    end
    return out
  end)

  html = html:gsub("<ul[^>]*>(.-)</ul>", function(content)
    local out = "\n"
    for item in content:gmatch("<li[^>]*>(.-)</li>") do
      out = out .. "- " .. item:gsub("^%s+", "") .. "\n"
    end
    return out
  end)

  html = html:gsub("<p[^>]*>(.-)</p>", "\n%1\n")

  -- Marimo's mo.md() emits `<span class="paragraph">…</span>` instead of
  -- `<p>…</p>` for prose paragraphs. Convert those to paragraph breaks so
  -- consecutive sentences don't end up jammed together as one line.
  html = html:gsub('<span class="paragraph"[^>]*>(.-)</span>', "\n%1\n")

  html = html:gsub("<br%s*/?>", "\n")

  -- Inline: keep markdown markers so the renderer can highlight them.
  -- Order matters: bold-strong before em-italic so `<strong><em>x</em></strong>`
  -- becomes `***x***` rather than `**<em>x</em>**`.
  html = html:gsub("<strong[^>]*>(.-)</strong>", "**%1**")
  html = html:gsub("<b[^>]*>(.-)</b>", "**%1**")
  html = html:gsub("<em[^>]*>(.-)</em>", "*%1*")
  html = html:gsub("<i[^>]*>(.-)</i>", "*%1*")
  html = html:gsub("<code[^>]*>(.-)</code>", "`%1`")
  html = html:gsub(
    '<a [^>]*href="([^"]*)"[^>]*>(.-)</a>',
    function(href, text) return "[" .. text .. "](" .. href .. ")" end
  )
  html = html:gsub('<a [^>]*href=\'([^\']*)\'[^>]*>(.-)</a>',
    function(href, text) return "[" .. text .. "](" .. href .. ")" end
  )

  -- Anything left (span wrappers, divs, etc.) drops to raw content.
  html = html:gsub("<[^>]+>", "")
  html = decode_entities(html)

  return html
end

-- ── inline parser ─────────────────────────────────────────────────────────

-- Walk a single line of markdown and split it into highlighted chunks for a
-- virt_line. Inline forms recognised:
--   `code`              → MarimoMarkdownInlineCode
--   **bold**            → MarimoMarkdownBold
--   *italic*            → MarimoMarkdownItalic
--   [text](url)         → MarimoMarkdownLink (text + dim url)
local function build_inline_chunks(line, base_hl)
  base_hl = base_hl or "MarimoOutputText"
  local chunks = {}
  local i, len = 1, #line
  local plain_start = i

  local function flush(upto)
    if upto > plain_start then
      table.insert(chunks, { line:sub(plain_start, upto - 1), base_hl })
    end
  end

  while i <= len do
    local c = line:sub(i, i)

    if c == "`" then
      local close = line:find("`", i + 1, true)
      if close then
        flush(i)
        table.insert(chunks, { line:sub(i + 1, close - 1), "MarimoMarkdownInlineCode" })
        i = close + 1
        plain_start = i
      else
        i = i + 1
      end

    elseif c == "*" and line:sub(i, i + 1) == "**" then
      local close = line:find("**", i + 2, true)
      if close then
        flush(i)
        table.insert(chunks, { line:sub(i + 2, close - 1), "MarimoMarkdownBold" })
        i = close + 2
        plain_start = i
      else
        i = i + 1
      end

    elseif c == "*" then
      -- Single * for italic; avoid matching the second * of bold.
      local close = line:find("*", i + 1, true)
      -- Reject if the candidate is part of an adjacent **; that case was
      -- already handled by the bold branch above.
      if close and line:sub(close + 1, close + 1) ~= "*" then
        flush(i)
        table.insert(chunks, { line:sub(i + 1, close - 1), "MarimoMarkdownItalic" })
        i = close + 1
        plain_start = i
      else
        i = i + 1
      end

    elseif c == "[" then
      local close_text = line:find("]", i + 1, true)
      if close_text and line:sub(close_text + 1, close_text + 1) == "(" then
        local close_url = line:find(")", close_text + 2, true)
        if close_url then
          flush(i)
          local text = line:sub(i + 1, close_text - 1)
          local url = line:sub(close_text + 2, close_url - 1)
          table.insert(chunks, { text, "MarimoMarkdownLink" })
          table.insert(chunks, { " (" .. url .. ")", "Comment" })
          i = close_url + 1
          plain_start = i
        else
          i = i + 1
        end
      else
        i = i + 1
      end

    else
      i = i + 1
    end
  end

  flush(len + 1)

  if #chunks == 0 then chunks = { { line, base_hl } } end
  return chunks
end

-- ── block parser ──────────────────────────────────────────────────────────

local function trim_blank_tail(lines)
  while #lines > 0 do
    local last = lines[#lines]
    local only = #last == 1 and last[1][1] or nil
    if only and only:match("^%s*$") then
      table.remove(lines)
    else
      break
    end
  end
  return lines
end

-- Render an ordered list of markdown source lines into virt_lines chunks.
local function render_md_lines(md_lines)
  local virt = {}
  local in_code = false
  local saw_content = false
  local last_was_blank = false

  local function push(chunks)
    table.insert(virt, chunks)
    last_was_blank = false
  end
  -- Collapse runs of blank lines into a single spacer so html_to_md's
  -- block-level `\n…\n` wrappers don't accumulate into double-spacing.
  local function push_blank()
    if not saw_content or last_was_blank then return end
    table.insert(virt, { { "  ", "MarimoOutputText" } })
    last_was_blank = true
  end

  for _, raw in ipairs(md_lines) do
    local line = raw

    -- Code fences come first so we don't try to match markdown inside a
    -- fenced block. Opening fences print a top rule and the language tag;
    -- closing fences print a bottom rule. Without that split, two fences
    -- in a row both render as openings ("╭─ python" then "╭─ code").
    local fence = line:match("^```(.*)$")
    if fence then
      saw_content = true
      if not in_code then
        in_code = true
        push({ { "  ╭─ ", "MarimoMarkdownCodeBorder" },
               { fence ~= "" and fence or "code", "Comment" } })
      else
        in_code = false
        push({ { "  ╰─", "MarimoMarkdownCodeBorder" } })
      end
    elseif in_code then
      push({ { "  ", "MarimoMarkdownCodeBorder" },
             { "│ ", "MarimoMarkdownCodeBorder" },
             { line, "MarimoMarkdownCode" } })
      saw_content = true
    else
      -- Heading
      local hashes, htext = line:match("^(#+)%s+(.+)$")
      if hashes and #hashes <= 6 then
        local hl_group = "MarimoMarkdownH" .. tostring(#hashes)
        local prefix = (#hashes == 1) and "▍ " or "▎ "
        local chunks = { { "  ", "MarimoOutputText" },
                         { prefix, hl_group },
                         { htext, hl_group } }
        push(chunks)
        saw_content = true

      -- Horizontal rule
      elseif line:match("^%-%-%-+%s*$") or line:match("^%*%*%*+%s*$") then
        push({ { "  ", "MarimoOutputText" },
               { string.rep("─", 40), "MarimoMarkdownRule" } })
        saw_content = true

      -- Unordered list
      elseif line:match("^%s*[%-%*%+]%s+") then
        local indent, item = line:match("^(%s*)[%-%*%+]%s+(.+)$")
        indent = indent or ""
        local prefix = "  " .. indent .. "• "
        local inline = build_inline_chunks(item or "")
        local out = { { prefix, "MarimoMarkdownBullet" } }
        for _, ch in ipairs(inline) do table.insert(out, ch) end
        push(out)
        saw_content = true

      -- Ordered list
      elseif line:match("^%s*%d+%.%s+") then
        local indent, num, item = line:match("^(%s*)(%d+)%.%s+(.+)$")
        indent = indent or ""
        local prefix = "  " .. indent .. num .. ". "
        local inline = build_inline_chunks(item or "")
        local out = { { prefix, "MarimoMarkdownBullet" } }
        for _, ch in ipairs(inline) do table.insert(out, ch) end
        push(out)
        saw_content = true

      -- Block quote
      elseif line:match("^>%s?") then
        local quote = line:gsub("^>%s?", "")
        push({ { "  ", "MarimoOutputText" },
               { "▎ ", "MarimoMarkdownQuoteBorder" },
               { quote, "MarimoMarkdownQuote" } })
        saw_content = true

      -- Blank line
      elseif line:match("^%s*$") then
        push_blank()

      -- Default paragraph line
      else
        local inline = build_inline_chunks(line)
        local out = { { "  ", "MarimoOutputText" } }
        for _, ch in ipairs(inline) do table.insert(out, ch) end
        push(out)
        saw_content = true
      end
    end
  end

  -- Close any unterminated code block with a soft rule so the block has
  -- a defined bottom edge even when marimo's HTML stripped the closing fence.
  if in_code then
    push({ { "  ╰─", "MarimoMarkdownCodeBorder" } })
  end

  return trim_blank_tail(virt)
end

-- ── public entry ──────────────────────────────────────────────────────────

-- Render markdown (raw or marimo-HTML-wrapped) as a list of virt_line chunks.
function M.render(data)
  if type(data) ~= "string" or data == "" then return {} end

  -- HTML payload from mo.md(): unwrap and convert to markdown text first.
  local md
  if data:find("<", 1, true) and (data:find("</") or data:find("/>")) then
    md = html_to_md(data)
  else
    md = data
  end

  local md_lines = vim.split(md, "\n", { plain = true })
  return render_md_lines(md_lines)
end

-- Predicate exposed so output.lua can route HTML payloads that look like
-- mo.md() output to this renderer instead of strip-tags.
M.looks_like_marimo_md_html = looks_like_marimo_md_html

return M

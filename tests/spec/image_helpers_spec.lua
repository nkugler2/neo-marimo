-- F6.3: unit coverage for image.lua's pure string-extraction helpers —
-- extract_data_uri, extract_inline_svg, extract_virtual_file. These are
-- already public (M.extract_*, called directly from output.lua's render_html
-- routing), so no test-seam exposure was needed — just direct calls.

local t = require("helpers")
local image = require("neo-marimo.image")

-- ── extract_data_uri ────────────────────────────────────────────────────────

t.case("image: extract_data_uri finds an embedded base64 PNG in an <img> tag", function()
  local html = '<img src="data:image/png;base64,iVBORw0KGgoAAAANSU">'
  local mime, data = image.extract_data_uri(html)
  t.eq(mime, "image/png")
  t.eq(data, "iVBORw0KGgoAAAANSU")
end)

t.case("image: extract_data_uri stops at the first byte outside the base64 alphabet", function()
  -- The closing ")" here isn't part of the base64 char class, so the match
  -- (and the trailing-junk cleanup pass) must not swallow it into `data`.
  local html = 'style="background:url(data:image/jpeg;base64,QUJD)" other'
  local mime, data = image.extract_data_uri(html)
  t.eq(mime, "image/jpeg")
  t.eq(data, "QUJD")
end)

t.case("image: extract_data_uri returns nil for a non-string or a payload with no data URI", function()
  t.eq(image.extract_data_uri(nil), nil)
  t.eq(image.extract_data_uri(42), nil)
  t.eq((image.extract_data_uri("<p>no images here</p>")), nil)
end)

t.case("image: has_embedded_image mirrors extract_data_uri's match/no-match", function()
  t.ok(image.has_embedded_image('<img src="data:image/gif;base64,R0lGOD">'))
  t.ok(not image.has_embedded_image("<p>plain text</p>"))
end)

-- ── extract_inline_svg ───────────────────────────────────────────────────────

t.case("image: extract_inline_svg pulls a single-line <svg>...</svg> block", function()
  local html = '<div><svg width="10"><rect/></svg></div>'
  local svg = image.extract_inline_svg(html)
  t.eq(svg, '<svg width="10"><rect/></svg>')
end)

t.case("image: extract_inline_svg spans multiple lines (Lua's . matches newlines here)", function()
  local html = "before\n<svg>\n  <circle cx=\"5\"/>\n</svg>\nafter"
  local svg = image.extract_inline_svg(html)
  t.eq(svg, "<svg>\n  <circle cx=\"5\"/>\n</svg>")
end)

t.case("image: extract_inline_svg returns nil when there's no <svg> block", function()
  t.eq(image.extract_inline_svg("<p>no svg</p>"), nil)
  t.eq(image.extract_inline_svg(nil), nil)
end)

-- ── extract_virtual_file ─────────────────────────────────────────────────────

t.case("image: extract_virtual_file finds a @file reference with single-quoted attrs", function()
  -- marimo's HTML builder quotes attributes with single quotes.
  local html = "<img src='./@file/123-name.jpeg' alt=''>"
  t.eq(image.extract_virtual_file(html), "./@file/123-name.jpeg")
end)

t.case("image: extract_virtual_file finds a @file reference with double-quoted attrs", function()
  local html = '<img alt="" src="./@file/456-plot.png">'
  t.eq(image.extract_virtual_file(html), "./@file/456-plot.png")
end)

t.case("image: extract_virtual_file skips a non-@file <img src> and returns nil", function()
  local html = "<img src='https://example.com/pic.png'>"
  t.eq(image.extract_virtual_file(html), nil)
end)

t.case("image: extract_virtual_file returns nil for a non-string or no <img> at all", function()
  t.eq(image.extract_virtual_file(nil), nil)
  t.eq(image.extract_virtual_file("<p>no images</p>"), nil)
end)

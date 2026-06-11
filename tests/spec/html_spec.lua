-- Unit tests for lua/neo-marimo/html.lua against hand-built strings and the
-- real-marimo fixture corpus.

local t = require("helpers")
local html = require("neo-marimo.html")

-- ── entities / attrs / labels ─────────────────────────────────────────────

t.case("html: decode_entities named + numeric", function()
  t.eq(html.decode_entities("&amp;&lt;&gt;&quot;&apos;"), [[&<>"']])
  t.eq(html.decode_entities("a&#92;&quot;b"), 'a\\"b')
  t.eq(html.decode_entities("&#x27;x&#x27;"), "'x'")
  t.eq(html.decode_entities("&nbsp;&hellip;"), " …")
  -- Unknown named entities pass through untouched.
  t.eq(html.decode_entities("&bogus;"), "&bogus;")
end)

t.case("html: parse_attrs both quote styles + unquoted", function()
  local a = html.parse_attrs([[ x="1" y='two' z=3 data-label='&quot;hi&quot;']])
  t.eq(a.x, "1")
  t.eq(a.y, "two")
  t.eq(a.z, "3")
  t.eq(a["data-label"], '"hi"')
end)

t.case("html: json_attr unwraps double-encoded JSON", function()
  -- Single-encoded array.
  t.eq(html.json_attr('["a","b"]'), { "a", "b" })
  -- Double-encoded: JSON string whose content is JSON (marimo-table data-data).
  t.eq(html.json_attr([["[{\"x\":1}]"]]), { { x = 1 } })
  t.eq(html.json_attr("not json"), nil)
end)

t.case("html: clean_label strips entity+json+markdown wrapping", function()
  local raw = '&quot;&lt;span class=&#92;&quot;markdown prose&#92;&quot;&gt;'
    .. '&lt;span class=&#92;&quot;paragraph&#92;&quot;&gt;Slider 0-10'
    .. '&lt;/span&gt;&lt;/span&gt;&quot;'
  t.eq(html.clean_label(raw), "Slider 0-10")
  t.eq(html.clean_label("plain"), "plain")
end)

t.case("html: parse_initial_value primitives and json", function()
  t.eq(html.parse_initial_value("true"), true)
  t.eq(html.parse_initial_value("false"), false)
  t.eq(html.parse_initial_value("5"), 5)
  t.eq(html.parse_initial_value('"banana"'), "banana")
  t.eq(html.parse_initial_value("[20, 80]"), { 20, 80 })
  t.eq(html.parse_initial_value(nil), nil)
end)

-- ── parser structure ──────────────────────────────────────────────────────

t.case("html: parse simple nesting", function()
  local root = html.parse("<div a='1'><span>hi</span>tail</div>")
  t.eq(#root.children, 1)
  local div = root.children[1]
  t.eq(div.tag, "div")
  t.eq(div.attrs.a, "1")
  t.eq(div.children[1].tag, "span")
  t.eq(div.children[1].children[1].text, "hi")
  t.eq(div.children[2].text, "tail")
end)

t.case("html: unclosed tags don't hang and stay in tree", function()
  local root = html.parse("<div><span>hi")
  local div = root.children[1]
  t.eq(div.tag, "div")
  t.eq(div.children[1].tag, "span")
  t.eq(div.children[1].children[1].text, "hi")
end)

t.case("html: stray closing tag is ignored", function()
  local root = html.parse("</b><p>x</p>")
  t.eq(#root.children, 1)
  t.eq(root.children[1].tag, "p")
end)

t.case("html: bare '<' in prose is text, not a tag", function()
  local root = html.parse("a < b <em>c</em>")
  t.eq(html.text_content(root), "a < b c")
end)

t.case("html: void and self-closing elements", function()
  local root = html.parse("<p><img src='x'/><br><b>z</b></p>")
  local p = root.children[1]
  t.eq(p.children[1].tag, "img")
  t.eq(p.children[2].tag, "br")
  t.eq(p.children[3].tag, "b")
end)

t.case("html: comments dropped, raw-text script preserved", function()
  local root = html.parse("<div><!-- <b>not parsed</b> --><script>if (a<b) {}</script></div>")
  local div = root.children[1]
  t.eq(#div.children, 1)
  t.eq(div.children[1].tag, "script")
  t.eq(div.children[1].children[1].text, "if (a<b) {}")
end)

t.case("html: '>' inside quoted attribute value", function()
  local root = html.parse([[<div title="a>b">x</div>]])
  t.eq(root.children[1].attrs.title, "a>b")
  t.eq(html.text_content(root), "x")
end)

t.case("html: oversized payload returns empty tree + err", function()
  local big = string.rep("x", html.MAX_PARSE_BYTES + 1)
  local root, err = html.parse(big)
  t.eq(#root.children, 0)
  t.ok(err ~= nil, "expected an error for oversized payload")
end)

-- ── fixture round-trips ───────────────────────────────────────────────────
--
-- serialize(parse(x)) == x for every captured marimo payload. This is the
-- strongest guarantee that subtree serialization can feed the string-based
-- consumers (dataframe/markdown/image extractors) without corruption.

for _, name in ipairs(t.fixture_names()) do
  t.case("html: round-trip fixture " .. name, function()
    local src = t.fixture(name)
    local root, err = html.parse(src)
    t.ok(err == nil, "parse error: " .. tostring(err))
    t.eq(html.serialize(root), src, name .. " round-trip")
  end)
end

-- ── fixture structure spot-checks ─────────────────────────────────────────

t.case("html: slider fixture structure", function()
  local root = html.parse(t.fixture("slider"))
  local wrapper = root.children[1]
  t.eq(wrapper.tag, "marimo-ui-element")
  t.ok(wrapper.attrs["object-id"] ~= nil, "wrapper has object-id")
  local slider = wrapper.children[1]
  t.eq(slider.tag, "marimo-slider")
  t.eq(slider.attrs["data-start"], "0")
  t.eq(slider.attrs["data-stop"], "10")
  t.eq(slider.attrs["data-initial-value"], "5")
  t.eq(html.clean_label(slider.attrs["data-label"]), "Slider 0-10")
end)

t.case("html: tabs fixture structure", function()
  local root = html.parse(t.fixture("tabs_simple"))
  local tabs = html.find_first(root, function(n) return n.tag == "marimo-tabs" end)
  t.ok(tabs, "found marimo-tabs")
  local labels = html.json_attr(tabs.attrs["data-tabs"])
  t.eq(#labels, 2)
  t.eq(html.clean_label(labels[1]), "A")
  t.eq(html.clean_label(labels[2]), "B")
  local bodies = {}
  for _, c in ipairs(html.element_children(tabs)) do
    if c.attrs["data-kind"] == "tab" then table.insert(bodies, c) end
  end
  t.eq(#bodies, 2)
  -- First tab contains a vstack (flex div) with a slider inside.
  local slider = html.find_first(bodies[1], function(n) return n.tag == "marimo-slider" end)
  t.ok(slider, "slider inside first tab")
end)

t.case("html: marimo-table data-data decodes to rows", function()
  local root = html.parse(t.fixture("table"))
  local tbl = html.find_first(root, function(n) return n.tag == "marimo-table" end)
  t.ok(tbl, "found marimo-table")
  local rows = html.json_attr(tbl.attrs["data-data"])
  t.ok(type(rows) == "table" and #rows == 5, "5 rows decoded")
  t.eq(rows[1].a, 1)
  t.eq(rows[1].cat, "x")
end)

t.case("html: accordion fixture labels", function()
  local root = html.parse(t.fixture("accordion"))
  local acc = html.find_first(root, function(n) return n.tag == "marimo-accordion" end)
  t.ok(acc, "found marimo-accordion")
  local labels = html.json_attr(acc.attrs["data-labels"])
  t.eq(#labels, 2)
  t.eq(html.clean_label(labels[1]), "Section 1")
  t.eq(#html.element_children(acc), 2)
end)

t.case("html: vstack fixture is a flex column div", function()
  local root = html.parse(t.fixture("vstack_widgets"))
  local div = root.children[1]
  t.eq(div.tag, "div")
  t.match(div.attrs.style or "", "flex%-direction:%s*column")
  t.eq(#html.element_children(div), 3)
end)

t.case("html: hstack fixture is a flex row div", function()
  local root = html.parse(t.fixture("hstack_widgets"))
  local div = root.children[1]
  t.eq(div.tag, "div")
  t.match(div.attrs.style or "", "flex%-direction:%s*row")
end)

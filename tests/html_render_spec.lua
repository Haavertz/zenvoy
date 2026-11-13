vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local html = require("zenvoy.utils.html")
local Document = require("zenvoy.render.document")
local renderer = require("zenvoy.render.html")

local function render(source, options)
   local document = Document.new()
   renderer.render_into(document, source, vim.tbl_extend("force", { width = 60, fold_quotes = true }, options or {}))
   return document:finish()
end

local function text(document)
   return table.concat(document.lines, "\n")
end

local function marks(document, group)
   local result = {}
   for _, mark in ipairs(document.marks) do
      if mark.hl == group then
         result[#result + 1] = document.lines[mark.row + 1]:sub(mark.col + 1, mark.end_col)
      end
   end
   return result
end

local function items(document, kind)
   local result = {}
   for _, item in ipairs(document.items) do
      if item.kind == kind then result[#result + 1] = item end
   end
   return result
end

t.test("decodes Portuguese, Windows-1252 and legacy entities in one pass", function()
   t.equal("Promoção de Verão", html.decode_entities("Promo&ccedil;&atilde;o de Ver&atilde;o"))
   t.equal("’ … €", html.decode_entities("&#146; &#133; &#128;"))
   t.equal("©2026 & a\194\160b", html.decode_entities("&copy2026 &amp a&nbspb"))
   t.equal("&lt;", html.decode_entities("&amp;lt;"))
   t.equal("&unknown;", html.decode_entities("&unknown;"))
   t.equal("Olá 👋", html.decode_entities("Ol&#225; &#x1F44B;"))
end)

t.test("parser closes implicit elements and ignores stray end tags outside cells", function()
   local root = html.parse("<p>one<p>two<div>three</div></td>four</p><ul><li>a<li>b</ul>")
   local names = {}
   for _, child in ipairs(root.children) do names[#names + 1] = type(child) == "table" and child.name or child end
   t.equal({ "p", "p", "div", "four", "ul" }, names)
   t.equal(2, #root.children[5].children)
   local cells = html.parse("<table><tr><td><div>x</td><td>y</table>").children[1].children[1].children
   t.equal(2, #cells)
   t.equal("td", cells[2].name)
end)

t.test("hides head, styles, scripts, comments, preheaders and tracking pixels", function()
   local document = render([[<html><head><title>T</title><style>p{color:red}</style></head><body>
      <!--[if mso]><p>Outlook only</p><![endif]-->
      <div style="display:none;max-height:0;overflow:hidden">Preheader &zwnj;&nbsp;&zwnj;</div>
      <div style="max-height:0px; overflow:hidden !important">Also hidden</div>
      <span hidden>hidden attribute</span><script>alert(1)</script>
      <p>Visible&#8203; text</p><img src="https://t.example/p.gif" width="1" height="1">
   </body></html>]])
   t.equal("Visible text", text(document))
end)

t.test("separates paragraphs and headings and keeps hard line breaks", function()
   local document = render("<h1>Title</h1><p>First <b>bold</b> and <i>it</i>.</p><div>Line<br>break</div><div><br></div><div>after</div>")
   t.equal("Title\n\nFirst bold and it.\n\nLine\nbreak\n\nafter", text(document))
   t.equal({ "Title" }, marks(document, "ZenvoyHeading"))
   t.equal({ "Title", "bold" }, marks(document, "ZenvoyBold"))
   t.equal({ "it" }, marks(document, "ZenvoyItalic"))
end)

t.test("wraps at the width without breaking long URLs or links into separate items", function()
   local document = render([[<p>Aproveite descontos em <a href="https://shop.example/promo">produtos <b>muito</b>
      selecionados</a> hoje https://example.com/a/very/long/path/that/must/not/be/broken/across/lines</p>]],
      { width = 30 })
   for _, line in ipairs(document.lines) do
      assert(vim.api.nvim_strwidth(line) <= 30 or line:find("^https://"), line)
   end
   assert(text(document):find("https://example.com/a/very/long/path/that/must/not/be/broken/across/lines", 1, true))
   local links = items(document, "link")
   t.equal("https://shop.example/promo", links[1].url)
   -- One item per wrapped line of the same anchor, sharing its group.
   for _, link in ipairs(links) do t.equal(links[1].group, link.group) end
   local url_marks = 0
   for _, mark in ipairs(document.marks) do
      if mark.url then url_marks = url_marks + 1 end
   end
   t.equal(#links, url_marks)
end)

t.test("only http, https and mailto links become actionable", function()
   local document = render([[<a href="javascript:alert(1)">js</a> <a href="#top">anchor</a>
      <a href="file:///etc/passwd">file</a> <a href=" https://ok.example/a b ">ok</a>
      <a href="mailto:a@b.example">mail</a>]])
   local urls = {}
   for _, link in ipairs(items(document, "link")) do urls[#urls + 1] = link.url end
   t.equal({ "https://ok.example/ab", "mailto:a@b.example" }, urls)
end)

t.test("lists use bullets, numbering and hanging indents", function()
   local document = render([[<ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul>
      <ol start="3"><li>Third</li><li>A long item that needs to wrap onto the next line</li></ol>]], { width = 30 })
   t.equal({ "  • One", "  • Two", "    ◦ Nested", "", "  3. Third", "  4. A long item that needs to",
      "     wrap onto the next line" }, document.lines)
end)

t.test("quotes get bars, are folded when long, and nest", function()
   local document = render([[<p>Reply</p><div>On Monday, Carol wrote:</div>
      <blockquote><p>One</p><p>Two</p><blockquote>Nested</blockquote></blockquote>]])
   t.equal({ "Reply", "", "On Monday, Carol wrote:", "", "│ One", "│", "│ Two", "│", "│ │ Nested" }, document.lines)
   t.equal({ { start = 4, finish = 8 } }, document.folds)
   local short = render("<blockquote>Short</blockquote>")
   t.equal({}, short.folds)
   t.equal({}, render("<blockquote><p>a</p><p>b</p><p>c</p></blockquote>", { fold_quotes = false }).folds)
end)

t.test("preformatted text keeps spacing and rules span the width", function()
   local document = render("<pre>  a  b\n\tc</pre><hr><p>after</p>", { width = 20 })
   t.equal({ "  a  b", "    c", "", string.rep("─", 20), "", "after" }, document.lines)
end)

t.test("data tables align columns while layout tables are linearized", function()
   local data = render([[<table><thead><tr><th>Item</th><th>Qty</th></tr></thead>
      <tr><td>Pen</td><td>2</td></tr><tr><td>Notebook</td><td>10</td></tr></table>]])
   t.equal({ "Item      Qty", "─────────────", "Pen       2", "Notebook  10" }, data.lines)
   local layout = render([[<table role="presentation"><tr><td><h2>Column A</h2><p>Text A</p></td>
      <td><p>Text B</p></td></tr></table>]])
   t.equal({ "Column A", "", "Text A", "", "Text B" }, layout.lines)
   local wide = render("<table><tr><td>" .. string.rep("x", 40) .. "</td><td>" .. string.rep("y", 40) .. "</td></tr></table>")
   t.equal(2, #wide.lines)
end)

t.test("images become markers in place, resolved by source", function()
   local resolved = {}
   local document = render([[<p>Logo: <img src="cid:logo" alt="Company"> and
      <a href="https://shop.example"><img src="https://img.example/banner.png"></a>
      <img src="unknown:x"> <img src="https://img.example/spacer.gif" alt=""></p>]], {
      resolve_image = function(src)
         resolved[#resolved + 1] = src
         if src == "cid:logo" then return { kind = "embedded", name = "logo.png" } end
         if src:find("banner") then return { kind = "remote", name = "Remote image" } end
      end,
   })
   -- Unresolvable images without alternative text are decoration and are omitted.
   t.equal("Logo: [Image: Company] and [Image: Remote image]", text(document))
   local images = items(document, "image")
   t.equal(2, #images)
   t.equal("logo.png", images[1].image.name)
   t.equal("https://shop.example", images[2].url)
   t.equal("[Image: Company]", document.lines[1]:sub(images[1].col + 1, images[1].end_col))
end)

t.test("plain-text export for quoting keeps link targets and uses > quotes", function()
   t.equal("Hello there <https://x.example/y> and a@b.example\n\n> quoted\n>\n>   - item",
      html.to_text([[<p>Hello <a href="https://x.example/y">there</a> and
         <a href="mailto:a@b.example">a@b.example</a></p><blockquote><p>quoted</p><ul><li>item</li></ul></blockquote>]]))
   t.equal("Hello & welcome!\n\nSecond line.\nBye.", html.to_text("<p>Hello &amp; welcome!</p><p>Second line.<br>Bye.</p>"))
end)

t.test("renders large newsletters quickly", function()
   local rows = {}
   for index = 1, 2000 do
      rows[#rows + 1] = ('<tr><td><p>Row %d <a href="https://e.example/%d">link</a> &nbsp;text</p></td></tr>'):format(index, index)
   end
   local started = vim.uv.hrtime()
   local document = render("<table>" .. table.concat(rows) .. "</table>", { width = 100 })
   local elapsed = (vim.uv.hrtime() - started) / 1e6
   t.equal(2000, #items(document, "link"))
   assert(elapsed < 2000, ("rendering took %d ms"):format(elapsed))
end)

t.finish("html_render_spec")

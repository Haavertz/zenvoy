vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local Document = require("zenvoy.render.document")
local plain = require("zenvoy.render.plain")

local function render(text, options)
   local document = Document.new()
   plain.render_into(document, text, options or { fold_quotes = true })
   return document:finish()
end

t.test("keeps text verbatim, trimming only blank edges", function()
   local document = render("\n\nHello,\r\n\r\n  indented   text\n\n\n")
   t.equal({ "Hello,", "", "  indented   text" }, document.lines)
end)

t.test("finds URLs without trailing punctuation", function()
   t.equal({ { col = 4, end_col = 29, url = "https://example.com/a?b=1" } },
      plain.urls("See https://example.com/a?b=1."))
   t.equal("https://en.example.org/wiki/Foo_(bar)", plain.urls("(https://en.example.org/wiki/Foo_(bar))")[1].url)
   t.equal("https://example.com/x", plain.urls("<https://example.com/x>, ok")[1].url)
   t.equal({}, plain.urls("ftp://example.com and http:// alone"))
   local document = render("Visit https://example.com/x now")
   t.equal({ { kind = "link", row = 0, col = 6, end_col = 27, url = "https://example.com/x" } }, document.items)
end)

t.test("highlights and folds long quotes and dims the signature", function()
   local document = render("Reply\n\nOn Monday Carol wrote:\n> one\n> two\n>\n> three\n\n-- \nCarol\nhttps://carol.example")
   t.equal({ { start = 3, finish = 6 } }, document.folds)
   local groups = {}
   for _, mark in ipairs(document.marks) do groups[mark.row] = groups[mark.row] or mark.hl end
   t.equal("ZenvoyQuote", groups[3])
   t.equal(nil, groups[2])
   t.equal("ZenvoySignature", groups[8])
   t.equal("ZenvoySignature", groups[9])
   t.equal({}, render("> short\n> quote").folds)
   t.equal({}, render("> a\n> b\n> c\n> d", { fold_quotes = false }).folds)
end)

t.finish("plain_render_spec")

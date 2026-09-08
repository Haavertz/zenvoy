vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local decode = require("zenvoy.himalaya.message").decode
local function fixture()
   return vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/messages/nested.json"), "\n"))
end

t.test("exposes inline image attachments without saving them", function()
   local message, err = decode(vim.json.encode(fixture()))
   t.equal(nil, err)
   t.equal(1, #message.images)
   t.equal("embedded", message.images[1].kind)
   t.equal("logo.png", message.images[1].name)
   t.equal("image/png", message.images[1].mime)
   t.equal("logo", message.images[1].cid)
   t.equal(14, #message.images[1].data)
end)

t.test("finds remote and data images while deduplicating CID references", function()
   local value = fixture()
   value.parts[5].body.Html = [[
      <img src="cid:logo" alt="Logo"><IMG ALT='Photo' SRC='https://images.example.test/p.png?a=1&amp;b=2'>
      <img src="https://images.example.test/p.png?a=1&amp;b=2">
      <img src="data:image/png;base64,YWJj" alt="Embedded photo">
      <img src="file:///etc/passwd"><img src="javascript:alert(1)">
   ]]
   local message, err = decode(vim.json.encode(value))
   t.equal(nil, err)
   t.equal(3, #message.images)
   t.equal("remote", message.images[2].kind)
   t.equal("https://images.example.test/p.png?a=1&b=2", message.images[2].url)
   t.equal("Photo", message.images[2].name)
   t.equal("data", message.images[3].kind)
end)

t.finish("image_sources_spec")

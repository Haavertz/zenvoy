vim.opt.runtimepath:prepend(vim.fn.getcwd())

local t = dofile("tests/helpers.lua")
local Client = require("zenvoy.himalaya.client")

-- Captured from Himalaya 2.1.0 reading synthetic messages in a temporary Maildir.
local function fixture(name)
   return table.concat(vim.fn.readfile("tests/fixtures/messages/" .. name .. ".json"), "\n")
end

local function read(output, options, mailbox, process_error, read_options)
   local result = {}
   local request = { cancel = function() end }
   local client = Client.new({ run = function(_, command, callback)
      result.command = command
      callback(process_error, output)
      return request
   end }, options)
   t.equal(request, client:read_message("native/id with spaces", mailbox, function(err, message)
      result.err, result.message = err, message
   end, read_options))
   return result
end

t.test("reads the backend ID in the same default mailbox as the listing", function()
   local result = read(fixture("plain"))
   t.equal({ "himalaya", "message", "read", "--json", "--log-level", "off", "--", "native/id with spaces" }, result.command)
   t.equal(nil, result.err)
   t.equal("Plain email", result.message.subject)
   t.equal({ { name = "Alice", email = "alice@example.com" } }, result.message.from)
   t.equal({ { name = "Bob", email = "bob@example.com" } }, result.message.to)
   t.equal({}, result.message.cc)
   t.equal("Hello, Bob!\n\nRegards,\nAlice\n", result.message.body)
end)

t.test("supports an explicit native mailbox and custom executable", function()
   local result = read(fixture("plain"), { executable = "/custom path/himalaya" }, "[Gmail]/Sent Mail")
   t.equal({ "/custom path/himalaya", "message", "read", "--mailbox", "[Gmail]/Sent Mail",
      "--json", "--log-level", "off", "--", "native/id with spaces" }, result.command)
end)

t.test("marks a read as seen only when explicitly requested", function()
   local result = read(fixture("plain"), nil, "Archive", nil, { seen = true })
   t.equal({ "himalaya", "message", "read", "--mailbox", "Archive", "--seen",
      "--json", "--log-level", "off", "--", "native/id with spaces" }, result.command)
   result = read(fixture("plain"), nil, nil, nil, { seen = false })
   assert(not vim.tbl_contains(result.command, "--seen"))
end)

t.test("normalizes Reply-To in known and custom Himalaya header forms", function()
   for _, name in ipairs({ "reply_to", "reply-to", { other = "Reply-To" } }) do
      local value = vim.json.decode(fixture("plain"))
      value.parts[1].headers[#value.parts[1].headers + 1] = {
         name = name, value = { Address = { List = { { address = "replies@example.com" } } } },
      }
      t.equal({ { email = "replies@example.com" } }, read(vim.json.encode(value)).message.reply_to)
   end
end)

t.test("decodes recipients and groups and prefers the plain MIME alternative", function()
   local result = read(fixture("multipart"))
   t.equal(nil, result.err)
   t.equal("Olá", result.message.subject)
   t.equal(2, #result.message.to)
   t.equal({ { name = "Dan", email = "dan@example.com" }, { name = "Eve", email = "eve@example.com" } }, result.message.cc)
   t.equal("Olá, Bob!\nSecond line.", result.message.body)
end)

t.test("accepts custom header names serialized as objects before the message headers", function()
   local value = vim.json.decode(fixture("multipart"))
   -- Same header-name variants found in message 30223, with synthetic content.
   for _, name in ipairs({ "Delivered-To", "X-Received", "Authentication-Results", "X-Custom" }) do
      table.insert(value.parts[1].headers, 1, {
         name = { other = name }, value = { Text = "synthetic header value" },
      })
   end
   local result = read(vim.json.encode(value))
   t.equal(nil, result.err)
   t.equal("Olá", result.message.subject)
   t.equal("alice@example.com", result.message.from[1].email)
   t.equal("Olá, Bob!\nSecond line.", result.message.body)
end)

t.test("reads nested mixed, alternative and related MIME without mixing in attachments", function()
   local result = read(fixture("nested"))
   t.equal(nil, result.err)
   t.equal("Nested MIME with encoded content", result.message.subject)
   t.equal("Olá, Bob!\nDecoded base64 body.\n", result.message.body)
end)

t.test("falls back to the HTML alternative when the plain body is blank", function()
   local value = vim.json.decode(fixture("multipart"))
   value.parts[2].body.Text = " \r\n\t"
   value.parts[3].body.Html = "<h1>Message title</h1><p>The readable content is here.</p>"
   local result = read(vim.json.encode(value))
   t.equal(nil, result.err)
   assert(result.message.body:find("Message title", 1, true), result.message.body)
   assert(result.message.body:find("The readable content is here.", 1, true), result.message.body)
end)

t.test("renders HTML-only mail as readable text", function()
   local result = read(fixture("html"))
   t.equal(nil, result.err)
   assert(result.message.body:find("Hello & welcome!", 1, true))
   assert(result.message.body:find("Second line.\nBye.", 1, true))
   assert(not result.message.body:find("<", 1, true))
   assert(not result.message.body:find("color:red", 1, true))
end)

t.test("accepts an empty body and absent headers", function()
   local result = read(fixture("empty"))
   t.equal(nil, result.err)
   t.equal("", result.message.body)
   t.equal({}, result.message.from)
   t.equal({}, result.message.to)
   t.equal({}, result.message.cc)
end)

t.test("handles nullable address fields and does not render attachment contents", function()
   local value = vim.json.decode(fixture("plain"))
   value.parts[1].headers[1].value.Address.List[1].name = vim.NIL
   value.parts[1].headers[3].value = "Empty"
   value.attachments = { 1 }
   value.parts[2] = { headers = {}, body = { Text = "Private attachment contents" } }
   local result = read(vim.json.encode(value))
   t.equal(nil, result.err)
   t.equal(nil, result.message.subject)
   t.equal({ { email = "alice@example.com" } }, result.message.from)
   assert(not result.message.body:find("Private attachment", 1, true))
end)

t.test("HTML fallback decodes numeric entities and removes scripts and styles", function()
   local value = vim.json.decode(fixture("html"))
   value.parts[1].body.Html = '<STYLE>hidden</STYLE><SCRIPT>hidden()</SCRIPT><p>Ol&#225; &#x1F44B;</p><p>&lt;hello&gt;</p>'
   local result = read(vim.json.encode(value))
   t.equal(nil, result.err)
   assert(result.message.body:find("Olá 👋", 1, true), result.message.body)
   assert(result.message.body:find("<hello>", 1, true), result.message.body)
   assert(not result.message.body:find("hidden", 1, true))
end)

t.test("rejects malformed messages and invalid MIME references before rendering", function()
   local malformed = { "not-json", "null", "[]", "{}", '{"parts":[]}',
      '{"parts":[null]}', '{"parts":[{}],"text_body":[0]}' }
   for _, mutate in ipairs({
      function(m) m.parts[1].headers = false end,
      function(m) m.parts[1].headers[1].name = { other = 42 } end,
      function(m) m.parts[1].headers[1].value.Address.List[1].address = 42 end,
      function(m) m.parts[1].headers[3].value.Text = false end,
      function(m) m.text_body = { 8 } end,
      function(m) m.text_body = { -1 } end,
      function(m) m.text_body = { 0.5 } end,
      function(m) m.parts[1].body.Text = false end,
   }) do
      local value = vim.json.decode(fixture("plain"))
      mutate(value)
      malformed[#malformed + 1] = vim.json.encode(value)
   end
   for _, output in ipairs(malformed) do
      local result = read(output)
      assert(result.err and result.err:find("Invalid Himalaya JSON (message)", 1, true), output)
      t.equal(nil, result.message)
   end
end)

t.test("reports contextual process failures", function()
   local result = read(nil, nil, nil, "message not found")
   assert(result.err:find("Read Himalaya message", 1, true))
   assert(result.err:find("message not found", 1, true))
   t.equal(nil, result.message)
end)

t.finish("message_spec")

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local Client = require("zenvoy.himalaya.client")

local source = table.concat(vim.fn.readfile("tests/fixtures/messages/plain.json"), "\n")
local preview = "From: Bob <bob@example.com>\r\nIn-Reply-To: <original@example.com>\r\n"
   .. "References: <original@example.com>\r\n\r\nignored preview body"

local function fixture()
   local calls, results = {}, {}
   local client = Client.new({ run = function(_, argv, callback, options)
      local call = { argv = argv, callback = callback, options = options, cancelled = 0 }
      calls[#calls + 1] = call
      return { cancel = function() call.cancelled = call.cancelled + 1 end }
   end })
   local function callback(err, draft) results[#results + 1] = { err = err, draft = draft } end
   return client, calls, results, callback
end

t.test("prepares source JSON and native thread metadata without marking seen or sending", function()
   local client, calls, results, callback = fixture()
   client:prepare_reply("-native id", "[Gmail]/Sent Mail", false, callback)
   t.equal(2, #calls)
   t.equal({ "himalaya", "message", "read", "--mailbox", "[Gmail]/Sent Mail", "--json",
      "--log-level", "off", "--", "-native id" }, calls[1].argv)
   t.equal({ "himalaya", "message", "reply", "--mailbox", "[Gmail]/Sent Mail", "--body=",
      "--log-level", "off", "--", "-native id" }, calls[2].argv)
   calls[2].callback(nil, preview)
   t.equal(0, #results)
   calls[1].callback(nil, source)
   t.equal(1, #results)
   t.equal(nil, results[1].err)
   t.equal("alice@example.com", results[1].draft.to)
   t.equal("-native id", results[1].draft.reply_context.id)
   t.equal("[Gmail]/Sent Mail", results[1].draft.reply_context.mailbox)
end)

t.test("preparation cancels siblings on failure and ignores late results", function()
   local client, calls, results, callback = fixture()
   client:prepare_reply("1", nil, false, callback)
   calls[1].callback("read failed")
   t.equal(1, calls[2].cancelled)
   calls[2].callback(nil, preview)
   t.equal(1, #results)
   assert(results[1].err:find("read failed", 1, true))
end)

t.test("explicit preparation cancellation stops both children and is idempotent", function()
   local client, calls, results, callback = fixture()
   local request = client:prepare_reply("1", nil, true, callback)
   request:cancel()
   request:cancel()
   t.equal(1, calls[1].cancelled)
   t.equal(1, calls[2].cancelled)
   calls[1].callback(nil, source)
   calls[2].callback(nil, preview)
   t.equal({}, results)
end)

t.test("compiles final body once before sending raw MIME and preserves editable empty Cc", function()
   local client, calls, results, callback = fixture()
   local draft = { to = "edited@example.com", cc = "", bcc = "blind@example.com",
      subject = "--subject $(literal)", body = "My reply\n\n> original quote", reply_context = {
         from = "Bob <bob@example.com>", in_reply_to = "<original@example.com>",
         references = "<original@example.com>", id = "1", mailbox = "Archive",
      } }
   client:send_message(draft, callback)
   t.equal(1, #calls)
   t.equal({ "himalaya", "message", "compose", "--to=edited@example.com", "--bcc=blind@example.com",
      "--subject=--subject $(literal)", "--log-level", "off" }, calls[1].argv)
   t.equal({ stdin = draft.body }, calls[1].options)
   assert(not vim.tbl_contains(calls[1].argv, "--send"))
   local compiled = "From: Bob <bob@example.com>\r\nTo: edited@example.com\r\n"
      .. "Bcc: blind@example.com\r\nContent-Type: text/plain\r\n\r\n"
      .. draft.body .. "\n\n-- \nConfigured signature"
   calls[1].callback(nil, compiled)
   t.equal(2, #calls)
   t.equal({ "himalaya", "message", "send", "--json", "--log-level", "off" }, calls[2].argv)
   assert(calls[2].options.stdin:find("In-Reply-To: <original@example.com>", 1, true))
   assert(calls[2].options.stdin:find(draft.body .. "\n\n-- \nConfigured signature", 1, true))
   assert(not calls[2].options.stdin:find("Cc:", 1, true))
   calls[2].callback(nil, '{"message":"Message successfully sent"}')
   t.equal({ {} }, results)
end)

t.test("invalid form fields never spawn a process", function()
   local client, calls, results, callback = fixture()
   client:send_message({ to = "one@example.com\nBcc: other@example.com" }, callback)
   t.equal({}, calls)
   assert(results[1].err)
end)

t.test("compile failure cannot send and send failure is delivered once", function()
   for _, phase in ipairs({ 1, 2 }) do
      local client, calls, results, callback = fixture()
      client:send_message({ to = "one@example.com", body = "Hello" }, callback)
      if phase == 2 then calls[1].callback(nil, "From: a@example.com\nTo: one@example.com\n\nHello") end
      calls[phase].callback("operation failed")
      calls[phase].callback(nil, "late")
      t.equal(phase, #calls)
      t.equal(1, #results)
      assert(results[1].err:find("operation failed", 1, true))
   end
end)

t.test("cancelling compilation prevents sending and suppresses its result", function()
   local client, calls, results, callback = fixture()
   local request = client:send_message({ to = "one@example.com", body = "Hello" }, callback)
   request:cancel()
   request:cancel()
   calls[1].callback(nil, "From: a@example.com\n\nHello")
   t.equal(1, calls[1].cancelled)
   t.equal(1, #calls)
   t.equal({}, results)
end)

t.test("supports immediately completed injected process results", function()
   local commands, results = {}, {}
   local client = Client.new({ run = function(_, argv, callback)
      commands[#commands + 1] = argv[3]
      if argv[3] == "read" then callback(nil, source)
      elseif argv[3] == "reply" then callback(nil, preview)
      elseif argv[3] == "compose" then callback(nil, "From: bob@example.com\n\nHello")
      else callback(nil, "sent") end
      return { cancel = function() end }
   end })
   client:prepare_reply("1", nil, false, function(err, draft)
      assert(not err, err)
      client:send_message(draft, function(send_error) results[#results + 1] = send_error or "sent" end)
   end)
   t.equal({ "read", "reply", "compose", "send" }, commands)
   t.equal({ "sent" }, results)
end)

t.finish("compose_client_spec")

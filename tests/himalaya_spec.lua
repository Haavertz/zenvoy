vim.opt.runtimepath:prepend(vim.fn.getcwd())

local t = dofile("tests/helpers.lua")
local Client = require("zenvoy.himalaya.client")

local function fixture(output, err, options)
   local captured, request = {}, { cancel = function() end }
   local process = { run = function(_, command, callback)
      captured.command = command
      callback(err, output)
      return request
   end }
   local client = Client.new(process, options)
   local function callback(failure, response)
      captured.err, captured.response = failure, response
   end
   return client, captured, callback, request
end

t.test("lists mailboxes and preserves identities and optional counts", function()
   local client, result, callback, request = fixture(
      '{"mailboxes":[{"id":"[Gmail]/Spam","name":"Spam","total":42,"unread":7}]}')
   t.equal(request, client:list_mailboxes(callback))
   t.equal({ "himalaya", "mailbox", "list", "--json", "--log-level", "off" }, result.command)
   t.equal(nil, result.err)
   t.equal({ { id = "[Gmail]/Spam", name = "Spam", total = 42, unread = 7 } }, result.response)
end)

t.test("lists 50 envelopes in the default mailbox and preserves message fields", function()
   local client, result, callback = fixture([[{"envelopes":[{
      "id":"30222","subject":"Test email","flags":[{"iana":"seen","raw":"\\Seen"}],
      "from":[{"name":null,"email":"alice@example.com"}],"to":[],"in-reply-to":[],
      "date":"2026-09-06T01:58:21Z","size":100,"has-attachment":null
   }]}]])
   client:list_envelopes(callback)
   t.equal({ "himalaya", "envelope", "list", "-s", "50", "--json", "--log-level", "off" }, result.command)
   t.equal(nil, result.err)
   t.equal("30222", result.response[1].id)
   t.equal("seen", result.response[1].flags[1].iana)
   t.equal("alice@example.com", result.response[1].from[1].email)
   t.equal(nil, result.response[1].from[1].name)
   t.equal(nil, result.response[1]["has-attachment"])
end)

t.test("supports a custom executable and page size without sharing options", function()
   local client, result, callback = fixture('{"envelopes":[]}', nil,
      { executable = "/path with spaces/himalaya", page_size = 10 })
   client:list_envelopes(callback)
   t.equal({ "/path with spaces/himalaya", "envelope", "list", "-s", "10", "--json", "--log-level", "off" }, result.command)
   local default, other, on_result = fixture('{"envelopes":[]}')
   default:list_envelopes(on_result)
   t.equal("himalaya", other.command[1])
   t.equal("50", other.command[5])
end)

t.test("accepts empty lists and nullable optional collections", function()
   local client, result, callback = fixture('{"mailboxes":[]}')
   client:list_mailboxes(callback)
   t.equal({}, result.response)
   client, result, callback = fixture('{"envelopes":[{"id":"1","flags":null,"from":null}]}')
   client:list_envelopes(callback)
   t.equal(nil, result.err)
   t.equal(nil, result.response[1].flags)
end)

t.test("adds operation context to process and JSON errors", function()
   for _, operation in ipairs({ "mailboxes", "envelopes" }) do
      local client, result, callback = fixture(nil, "authentication failed")
      client["list_" .. operation](client, callback)
      assert(result.err:find(operation, 1, true))
      assert(result.err:find("authentication failed", 1, true))
      t.equal(nil, result.response)
      client, result, callback = fixture("not-json")
      client["list_" .. operation](client, callback)
      assert(result.err:find("Invalid Himalaya JSON", 1, true))
      assert(result.err:find(operation, 1, true))
   end
end)

t.test("rejects malformed lists and records before they reach the UI", function()
   for _, output in ipairs({
      'null', '42', '[]', '{}', '{"envelopes":null}', '{"envelopes":{}}',
      '{"envelopes":{"id":"1"}}', '{"envelopes":[null]}', '{"envelopes":[1]}',
      '{"envelopes":[{}]}', '{"envelopes":[{"id":1}]}',
      '{"envelopes":[{"id":"1","subject":false}]}',
      '{"envelopes":[{"id":"1","flags":42}]}',
      '{"envelopes":[{"id":"1","flags":{}}]}',
      '{"envelopes":[{"id":"1","flags":[null]}]}',
      '{"envelopes":[{"id":"1","from":[42]}]}',
      '{"envelopes":[{"id":"1","from":[{"name":true}]}]}',
      '{"envelopes":[{"id":"1","has-attachment":"yes"}]}',
   }) do
      local client, result, callback = fixture(output)
      client:list_envelopes(callback)
      assert(result.err and result.err:find("Invalid Himalaya JSON", 1, true), output)
      t.equal(nil, result.response)
   end
   local client, result, callback = fixture('{"mailboxes":[{"id":"Inbox","total":"42"}]}')
   client:list_mailboxes(callback)
   assert(result.err, "invalid mailbox counts must be rejected")
end)

t.finish("himalaya_spec")

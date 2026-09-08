-- Real Himalaya 2.1 composition/read smoke tests against a disposable synthetic
-- Maildir. The only send operation is intercepted before it can spawn a process.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local Client = require("zenvoy.himalaya.client")
local Process = require("zenvoy.core.process")

if vim.fn.executable("himalaya") == 0 then
   print("himalaya_native_spec: skipped (Himalaya is not installed)")
   return
end

local temporary = vim.fn.tempname() .. "-zenvoy-native"
local maildir = temporary .. "/mail/INBOX"
local config = temporary .. "/config.toml"
for _, directory in ipairs({ "/cur", "/new", "/tmp" }) do vim.fn.mkdir(maildir .. directory, "p") end
vim.fn.writefile({
   "[accounts.zenvoy_test]",
   "default = true",
   'email = "bob@example.com"',
   'display-name = "Bob Example"',
   'signature = "ZenvoySyntheticSignature"',
   "[accounts.zenvoy_test.mailbox.alias]",
   'inbox = "INBOX"',
   "[accounts.zenvoy_test.maildir]",
   "root = " .. vim.json.encode(temporary .. "/mail"),
}, config)

local original = {
   "From: Alice <alice@example.com>",
   "Reply-To: Replies <replies@example.com>",
   "To: Bob <BOB@example.com>, Carol <carol@example.com>",
   "Cc: Carol <CAROL@example.com>, Dave <dave@example.com>",
   "Subject: Olá synthetic reply",
   "Date: Mon, 07 Sep 2026 12:00:00 +0000",
   "Message-ID: <original@example.com>",
   "References: <older@example.com>",
   "MIME-Version: 1.0",
   "Content-Type: text/plain; charset=utf-8",
   "", "Original synthetic content.", "Second line.",
}
vim.fn.writefile(original, maildir .. "/cur/original:2,")

local sent_raw, native_calls = nil, {}
local process = Process.new({ system = function(argv, options, callback)
   assert(argv[1] == "himalaya" and argv[2] == "message", "Native smoke only permits message operations")
   if argv[3] == "send" then
      sent_raw = options.stdin
      -- Delivery is intentionally mocked; no real send subprocess is launched.
      callback({ code = 0, stdout = '{"message":"synthetic send intercepted"}', stderr = "" })
      return { kill = function() end }
   end
   assert(vim.tbl_contains({ "read", "reply", "compose" }, argv[3]), "Disallowed native operation")
   assert(not vim.tbl_contains(argv, "--send") and not vim.tbl_contains(argv, "--save"), "Disallowed write flag")
   local command = { "himalaya", "--config", config, "--account", "zenvoy_test", "--backend", "maildir" }
   vim.list_extend(command, vim.list_slice(argv, 2))
   native_calls[#native_calls + 1] = command
   return vim.system(command, options, callback)
end })
local client = Client.new(process)

local function await_call(invoke)
   local done, result
   invoke(function(err, value) done, result = true, { err = err, value = value } end)
   assert(vim.wait(4000, function() return done end, 5), "Synthetic Himalaya operation timed out")
   assert(not result.err, result.err)
   return result.value
end

local function persist_compiled()
   assert(type(sent_raw) == "string" and sent_raw:find("\n\n", 1, true), "Expected compiled RFC 5322")
   vim.fn.writefile(vim.split(sent_raw, "\n", { plain = true }), maildir .. "/cur/compiled:2,")
   return await_call(function(callback) client:read_message("compiled", nil, callback) end)
end

t.test("native compose consumes stdin, preserves UTF-8 headers, and adds the account signature once", function()
   await_call(function(callback)
      client:send_message({ to = '"Doe, Jane" <jane@example.com>', cc = "", bcc = "blind@example.com",
         subject = "Olá --literal $(subject)", body = "Hello from stdin.\n`literal` body." }, callback)
   end)
   local decoded = persist_compiled()
   t.equal("Olá --literal $(subject)", decoded.subject)
   t.equal("jane@example.com", decoded.to[1].email)
   t.equal("bob@example.com", decoded.from[1].email)
   t.equal("Bob Example", decoded.from[1].name)
   t.equal("Hello from stdin.\n`literal` body.\n\n-- \nZenvoySyntheticSignature", vim.trim(decoded.body))
   assert(sent_raw:find("Bcc:", 1, true))
end)

t.test("native reply metadata survives editing the quote and clearing Cc without marking the source seen", function()
   local draft = await_call(function(callback) client:prepare_reply("original", nil, true, callback) end)
   t.equal("replies@example.com, carol@example.com", draft.to)
   t.equal("dave@example.com", draft.cc)
   t.equal("Re: Olá synthetic reply", draft.subject)
   t.equal("<original@example.com>", draft.reply_context.in_reply_to)
   t.equal("<older@example.com> <original@example.com>", draft.reply_context.references)
   assert(draft.body:find("> Original synthetic content.", 1, true))
   assert(not draft.body:find("ZenvoySyntheticSignature", 1, true))
   draft.body, draft.cc, draft.to = "Edited reply.\n\n> Edited quotation.", "", "edited@example.com"
   await_call(function(callback) client:send_message(draft, callback) end)
   local decoded = persist_compiled()
   t.equal("edited@example.com", decoded.to[1].email)
   t.equal({}, decoded.cc)
   t.equal("Edited reply.\n\n> Edited quotation.\n\n-- \nZenvoySyntheticSignature", vim.trim(decoded.body))
   assert(sent_raw:find("In-Reply-To: <original@example.com>", 1, true))
   assert(sent_raw:find("References: <older@example.com> <original@example.com>", 1, true))
   assert(not sent_raw:find("Original synthetic content.", 1, true))
   t.equal(1, vim.fn.filereadable(maildir .. "/cur/original:2,"))
end)

t.test("native seen reads update the synthetic Maildir flag while preserving the original message ID", function()
   local first = await_call(function(callback)
      client:read_message("original", nil, callback, { seen = true })
   end)
   t.equal("Olá synthetic reply", first.subject)
   local paths = vim.fn.glob(maildir .. "/cur/original:2,*", false, true)
   t.equal(1, #paths)
   assert(vim.fn.fnamemodify(paths[1], ":t"):match("^original:2,[A-Za-z]*S[A-Za-z]*$"), paths[1])
   t.equal(0, vim.fn.filereadable(maildir .. "/cur/original:2,"))
   local second = await_call(function(callback)
      client:read_message("original", nil, callback, { seen = true })
   end)
   t.equal(first.subject, second.subject)
   t.equal(first.body, second.body)
   t.equal(paths, vim.fn.glob(maildir .. "/cur/original:2,*", false, true))
end)

-- Only delete the generated test directory, never an account path or user data.
assert(temporary:match("zenvoy%-native$"))
vim.fn.delete(temporary, "rf")
t.finish("himalaya_native_spec")

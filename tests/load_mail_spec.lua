vim.opt.runtimepath:prepend(vim.fn.getcwd())

local t = dofile("tests/helpers.lua")
local LoadMail = require("zenvoy.application.load_mail")

local function fixture()
   local pending, cancelled, calls = {}, {}, {}
   local client = {}
   for _, name in ipairs({ "mailboxes", "envelopes" }) do
      client["list_" .. name] = function(_, callback)
         pending[name] = callback
         return { cancel = function() cancelled[name] = (cancelled[name] or 0) + 1 end }
      end
   end
   local loader = LoadMail.new(client)
   local request = loader:run({
      on_success = function(response) calls[#calls + 1] = { response = response } end,
      on_error = function(err) calls[#calls + 1] = { err = err } end,
   })
   return pending, cancelled, calls, request, loader
end

t.test("starts both requests concurrently and publishes one complete response in either order", function()
   for _, order in ipairs({ { "mailboxes", "envelopes" }, { "envelopes", "mailboxes" } }) do
      local pending, _, calls = fixture()
      assert(pending.mailboxes and pending.envelopes)
      local data = {
         mailboxes = { { id = "Inbox", total = 42, unread = 7 } },
         envelopes = { { id = "30222", subject = "Test email" } },
      }
      pending[order[1]](nil, data[order[1]])
      t.equal({}, calls)
      pending[order[2]](nil, data[order[2]])
      t.equal({ { response = data } }, calls)
   end
end)

t.test("propagates either failure once and cancels the pending sibling", function()
   for _, name in ipairs({ "mailboxes", "envelopes" }) do
      local pending, cancelled, calls = fixture()
      pending[name](name .. " failed")
      t.equal({ { err = name .. " failed" } }, calls)
      local other = name == "mailboxes" and "envelopes" or "mailboxes"
      t.equal(1, cancelled[other])
      pending[other]("late error")
      t.equal(1, #calls)
   end
end)

t.test("cancel is idempotent and suppresses all late results", function()
   local pending, cancelled, calls, request = fixture()
   request:cancel()
   request:cancel()
   t.equal({ mailboxes = 1, envelopes = 1 }, cancelled)
   pending.mailboxes(nil, { { id = "Old" } })
   pending.envelopes("late error")
   t.equal({}, calls)
end)

t.test("duplicate responses cannot complete an unfinished request", function()
   local pending, _, calls, request = fixture()
   pending.mailboxes(nil, {})
   pending.mailboxes(nil, { { id = "Duplicate" } })
   t.equal({}, calls)
   pending.envelopes(nil, {})
   t.equal({ { response = { mailboxes = {}, envelopes = {} } } }, calls)
   request:cancel()
   t.equal(1, #calls)
end)

t.test("handles immediate callbacks without losing results", function()
   local response
   local loader = LoadMail.new({
      list_mailboxes = function(_, done) done(nil, {}) end,
      list_envelopes = function(_, done) done(nil, {}) end,
   })
   loader:run({ on_success = function(value) response = value end, on_error = error })
   t.equal({ mailboxes = {}, envelopes = {} }, response)
end)

t.test("concurrent runs on one instance keep separate request state", function()
   local pending, _, calls, _, loader = fixture()
   local old_mailboxes, old_envelopes = pending.mailboxes, pending.envelopes
   local response
   loader:run({ on_success = function(value) response = value end, on_error = error })
   old_mailboxes(nil, { { id = "Old" } })
   pending.mailboxes(nil, { { id = "New" } })
   old_envelopes(nil, {})
   t.equal("Old", calls[1].response.mailboxes[1].id)
   t.equal(nil, response)
   pending.envelopes(nil, {})
   t.equal("New", response.mailboxes[1].id)
end)

t.finish("load_mail_spec")

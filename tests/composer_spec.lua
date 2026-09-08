vim.opt.runtimepath:prepend(vim.fn.getcwd())

local t = dofile("tests/helpers.lua")
local Composer = require("zenvoy.ui.composer")
local controllers = {}

local function flush()
   vim.wait(20, function() return false end, 5)
end

local function make()
   for _, controller in ipairs(controllers) do controller:detach() end
   flush()
   local observed = { choices = {}, sends = {}, preparations = {}, activities = {}, notices = {} }
   local controller = Composer.new({
      choose = function(items, options, callback)
         observed.choices[#observed.choices + 1] = { items = items, options = options, callback = callback }
      end,
      send = function(draft, callback)
         local request = { draft = draft, callback = callback, cancelled = false }
         function request:cancel() self.cancelled = true end
         observed.sends[#observed.sends + 1] = request
         return request
      end,
      prepare_reply = function(id, mailbox, all, callback)
         local request = { id = id, mailbox = mailbox, all = all, callback = callback, cancelled = false }
         function request:cancel() self.cancelled = true end
         observed.preparations[#observed.preparations + 1] = request
         return request
      end,
      activity = function(label)
         local item = { label = label, finishes = 0 }
         observed.activities[#observed.activities + 1] = item
         return function() item.finishes = item.finishes + 1 end
      end,
      notify = function(message) observed.notices[#observed.notices + 1] = message end,
   })
   controllers[#controllers + 1] = controller
   return controller, observed
end

local function map(session, field, mode, lhs)
   for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(session.fields[field].bufnr, mode)) do
      if mapping.lhs == lhs then return mapping.callback end
   end
end

local function write(session, field, text)
   vim.api.nvim_buf_set_lines(session.fields[field].bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
end

local function value(session, field)
   return table.concat(vim.api.nvim_buf_get_lines(session.fields[field].bufnr, 0, -1, false), "\n")
end

local function send(controller, observed)
   map(controller.session, "body", "n", "<C-S>")()
   observed.choices[#observed.choices].callback("Send")
end

t.test("new composer has five scratch fields, semantic navigation, and restores focus", function()
   local controller, observed = make()
   local previous = vim.api.nvim_get_current_win()
   controller:open()
   flush()
   local session = controller.session
   t.equal(true, controller:is_open())
   t.equal(session.fields.to.winid, vim.api.nvim_get_current_win())
   for _, name in ipairs({ "to", "cc", "bcc", "subject", "body" }) do
      local popup = session.fields[name]
      t.equal(false, vim.bo[popup.bufnr].swapfile)
      t.equal(false, vim.bo[popup.bufnr].undofile)
      t.equal("nofile", vim.bo[popup.bufnr].buftype)
      t.equal(true, vim.bo[popup.bufnr].modifiable)
      for _, mode in ipairs({ "n", "i" }) do
         assert(map(session, name, mode, "<Tab>"), "missing Tab on " .. name .. "/" .. mode)
         assert(map(session, name, mode, "<S-Tab>"), "missing reverse Tab")
         assert(map(session, name, mode, "<C-S>"), "missing send")
      end
      for _, key in ipairs({ "c", "r", "s" }) do t.equal(nil, map(session, name, "n", key)) end
      t.equal(nil, map(session, name, "i", "<Esc>"))
   end
   map(session, "to", "n", "<Tab>")()
   t.equal(session.fields.cc.winid, vim.api.nvim_get_current_win())
   map(session, "cc", "n", "<S-Tab>")()
   t.equal(session.fields.to.winid, vim.api.nvim_get_current_win())
   map(session, "to", "n", "<S-Tab>")()
   t.equal(session.fields.body.winid, vim.api.nvim_get_current_win())
   map(session, "body", "n", "<Tab>")()
   t.equal(session.fields.to.winid, vim.api.nvim_get_current_win())
   controller:open()
   t.equal(session, controller.session)
   local closed = false
   controller:request_close(function() closed = true end)
   flush()
   t.equal(false, controller:is_open())
   t.equal(true, closed)
   t.equal(previous, vim.api.nvim_get_current_win())
   t.equal(0, #observed.choices)
end)

t.test("reply preparation is locked, cancellable, and focuses above its editable quote", function()
   local controller, observed = make()
   controller:open({ id = "native/id", mailbox = "[Gmail]/Sent", all = true })
   local session, request = controller.session, observed.preparations[1]
   t.equal("native/id", request.id)
   t.equal("[Gmail]/Sent", request.mailbox)
   t.equal(true, request.all)
   t.equal(false, vim.bo[session.fields.body.bufnr].modifiable)
   t.equal("Preparing reply", observed.activities[1].label)
   t.equal("", value(session, "body"))
   request.callback(nil, { to = "alice@example.test", cc = "bob@example.test", subject = "Re: Hello",
      body = "\n\nOn Monday Alice wrote:\n> Hello", reply_context = { message_id = "thread" } })
   flush()
   t.equal(1, observed.activities[1].finishes)
   t.equal("alice@example.test", value(session, "to"))
   t.equal("bob@example.test", value(session, "cc"))
   t.equal("Re: Hello", value(session, "subject"))
   t.equal(session.fields.body.winid, vim.api.nvim_get_current_win())
   t.equal({ 1, 0 }, vim.api.nvim_win_get_cursor(session.fields.body.winid))
   t.equal(true, vim.bo[session.fields.body.bufnr].modifiable)
   send(controller, observed)
   t.equal({ message_id = "thread" }, observed.sends[1].draft.reply_context)
end)

t.test("invalid recipients and multiline headers cannot reach confirmation or send", function()
   local controller, observed = make()
   controller:open()
   local session = controller.session
   map(session, "body", "n", "<C-S>")()
   t.equal(0, #observed.choices)
   assert(observed.notices[1]:find("recipient", 1, true), observed.notices[1])
   write(session, "bcc", "private@example.test")
   write(session, "subject", "Hello\nBcc: injected@example.test")
   map(session, "body", "n", "<C-S>")()
   t.equal(0, #observed.choices)
   assert(observed.notices[2]:find("single line", 1, true), observed.notices[2])
   write(session, "subject", "Hello")
   send(controller, observed)
   t.equal(1, #observed.sends)
   t.equal("private@example.test", observed.sends[1].draft.bcc)
end)

t.test("confirmation freezes its snapshot and prevents duplicate sends", function()
   local controller, observed = make()
   controller:open()
   local session = controller.session
   write(session, "to", "Alice <alice@example.test>")
   write(session, "subject", "Snapshot")
   write(session, "body", "Original text")
   map(session, "body", "n", "<C-S>")()
   local choice = observed.choices[1]
   t.equal(false, vim.bo[session.fields.body.bufnr].modifiable)
   vim.bo[session.fields.body.bufnr].modifiable = true
   write(session, "body", "Changed after confirmation")
   choice.callback("Send")
   choice.callback("Send")
   map(session, "body", "n", "<C-S>")()
   t.equal(1, #observed.sends)
   t.equal("Original text", observed.sends[1].draft.body)
   t.equal("Sending email", observed.activities[1].label)
   t.equal(false, vim.bo[session.fields.body.bufnr].modifiable)
   local closed = false
   controller:request_close(function() closed = true end)
   t.equal(true, controller:is_open())
   t.equal(false, closed)
   t.equal(1, #observed.choices)
   observed.sends[1].callback(nil)
   flush()
   t.equal(false, controller:is_open())
   t.equal(1, observed.activities[1].finishes)
   assert(observed.notices[#observed.notices]:find("sent", 1, true))
end)

t.test("cancelled confirmation and failed sends retain editable text for retry", function()
   local controller, observed = make()
   controller:open()
   local session = controller.session
   write(session, "to", "alice@example.test")
   write(session, "body", "Keep my draft")
   map(session, "body", "n", "<C-S>")()
   observed.choices[1].callback(nil)
   t.equal(true, vim.bo[session.fields.body.bufnr].modifiable)
   t.equal(0, #observed.sends)
   send(controller, observed)
   observed.sends[1].callback("network failed")
   t.equal(true, controller:is_open())
   t.equal("Keep my draft", value(session, "body"))
   t.equal(true, vim.bo[session.fields.body.bufnr].modifiable)
   assert(observed.notices[1]:find("network failed", 1, true))
   send(controller, observed)
   t.equal(2, #observed.sends)
   observed.sends[1].callback(nil)
   t.equal(true, controller:is_open())
   t.equal(false, vim.bo[session.fields.body.bufnr].modifiable)
   observed.sends[2].callback(nil)
   t.equal(false, controller:is_open())
end)

t.test("obsolete confirmation callbacks cannot accept a later confirmation", function()
   local controller, observed = make()
   controller:open()
   local session = controller.session
   write(session, "to", "alice@example.test")
   map(session, "body", "n", "<C-S>")()
   local obsolete = observed.choices[1]
   obsolete.callback("Cancel")
   write(session, "body", "Latest text")
   map(session, "body", "n", "<C-S>")()
   obsolete.callback("Send")
   t.equal(0, #observed.sends)
   observed.choices[2].callback("Send")
   t.equal("Latest text", observed.sends[1].draft.body)
end)

t.test("discard confirmation preserves cancelled drafts and closes only on acceptance", function()
   local controller, observed = make()
   controller:open()
   write(controller.session, "body", "Unsaved text")
   local closes = 0
   controller:request_close(function() closes = closes + 1 end)
   observed.choices[1].callback("Keep editing")
   t.equal(true, controller:is_open())
   t.equal(0, closes)
   controller:request_close(function() closes = closes + 1 end)
   observed.choices[2].callback("Discard")
   t.equal(false, controller:is_open())
   t.equal(1, closes)
   controller:request_close(function() closes = closes + 1 end)
   t.equal(2, closes)
end)

t.test("an untouched prepared reply closes without a discard prompt", function()
   local controller, observed = make()
   controller:open({ id = "reply" })
   observed.preparations[1].callback(nil, { to = "alice@example.test", subject = "Re: Hello", body = "\n\n> Hello" })
   controller:request_close()
   t.equal(false, controller:is_open())
   t.equal(0, #observed.choices)
end)

t.test("cancelled preparations and confirmations cannot touch reopened composers", function()
   local controller, observed = make()
   controller:open({ id = "old", mailbox = "Inbox" })
   local request = observed.preparations[1]
   controller:request_close()
   t.equal(true, request.cancelled)
   t.equal(1, observed.activities[1].finishes)
   controller:open()
   local newer = controller.session
   request.callback(nil, { to = "stale@example.test", body = "Stale reply" })
   t.equal(newer, controller.session)
   t.equal("", value(newer, "to"))
   write(newer, "to", "fresh@example.test")
   map(newer, "to", "n", "<C-S>")()
   local confirm = observed.choices[1]
   controller:detach()
   controller:open()
   confirm.callback("Send")
   t.equal(0, #observed.sends)
   t.equal("", value(controller.session, "to"))
end)

t.test("detaching a dispatched send leaves delivery running without closing a newer draft", function()
   local controller, observed = make()
   controller:open()
   write(controller.session, "to", "alice@example.test")
   send(controller, observed)
   local request = observed.sends[1]
   controller:detach()
   t.equal(false, request.cancelled)
   controller:open()
   local newer = controller.session
   write(newer, "body", "New draft")
   request.callback(nil)
   request.callback(nil)
   t.equal(newer, controller.session)
   t.equal("New draft", value(newer, "body"))
   t.equal(1, #observed.notices)
   t.equal(1, observed.activities[1].finishes)
end)

t.test("preparation failures close the untouched form and cannot send an unthreaded reply", function()
   local controller, observed = make()
   controller:open({ id = "bad" })
   observed.preparations[1].callback("cannot prepare reply")
   t.equal(false, controller:is_open())
   t.equal(0, #observed.sends)
   t.equal(1, observed.activities[1].finishes)
   assert(observed.notices[1]:find("cannot prepare reply", 1, true))
end)

t.test("external field closure cancels preparation and cleans all composer windows", function()
   local controller, observed = make()
   local windows_before = #vim.api.nvim_list_wins()
   controller:open({ id = "pending" })
   vim.api.nvim_win_close(controller.session.fields.body.winid, true)
   flush()
   t.equal(false, controller:is_open())
   t.equal(true, observed.preparations[1].cancelled)
   t.equal(1, observed.activities[1].finishes)
   t.equal(windows_before, #vim.api.nvim_list_wins())
end)

t.test("synchronous preparation and delivery exceptions release their activity", function()
   local controller, observed = make()
   controller.prepare_reply = function() error("prepare spawn failed") end
   controller:open({ id = "exception" })
   t.equal(false, controller:is_open())
   t.equal(1, observed.activities[1].finishes)
   controller:open()
   write(controller.session, "to", "alice@example.test")
   write(controller.session, "body", "Preserve on failure")
   controller.send = function() error("send spawn failed") end
   send(controller, observed)
   t.equal(true, controller:is_open())
   t.equal(true, vim.bo[controller.session.fields.body.bufnr].modifiable)
   t.equal("Preserve on failure", value(controller.session, "body"))
   t.equal(1, observed.activities[2].finishes)
   assert(observed.notices[1]:find("prepare spawn failed", 1, true))
   assert(observed.notices[2]:find("send spawn failed", 1, true))
end)

for _, controller in ipairs(controllers) do controller:detach() end
t.finish("composer_spec")

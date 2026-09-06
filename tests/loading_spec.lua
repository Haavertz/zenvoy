vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Exercise the registered command with the real NUI layout and controlled child processes.
local t = dofile("tests/helpers.lua")
local original_system, original_readable = vim.system, vim.fn.filereadable
local original_writefile, original_notify = vim.fn.writefile, vim.notify
local jobs, notifications, welcome = {}, {}, nil

local function fake_system(command, options, on_exit)
   local job = { command = command, options = options, exit = on_exit, kills = 0 }
   function job:kill() self.kills = self.kills + 1 end
   jobs[#jobs + 1] = job
   return job
end

vim.system = fake_system
vim.fn.filereadable = function() return 1 end
vim.notify = function(message) notifications[#notifications + 1] = message end
package.loaded["zenvoy.ui.welcome"] = { create = function(callback) welcome = callback end }

local app, state = require("zenvoy"), require("zenvoy.state")
dofile("plugin/zenvoy.lua")

local function indicator()
   local border = state.sidebar_popup and state.sidebar_popup.border
   if not border or not vim.api.nvim_buf_is_valid(border.bufnr) then return end
   local row = vim.api.nvim_win_get_height(border.winid) - 1
   local footer = vim.api.nvim_buf_get_lines(border.bufnr, row, row + 1, false)[1]
   return footer:find("Loading", 1, true) and border.bufnr or nil
end

local function flush()
   vim.wait(30, function() return false end, 5)
end

local function complete(job, output, code, stderr)
   job.exit({ code = code or 0, stdout = output or "", stderr = stderr or "" })
   flush()
end

local function open()
   app.close()
   jobs, notifications = {}, {}
   app.setup()
   vim.system = fake_system
   vim.cmd.Zenvoy()
   assert(#jobs == 2, "opening must start both Himalaya commands")
   t.equal("himalaya", jobs[1].command[1])
   t.equal("mailbox", jobs[1].command[2])
   t.equal("envelope", jobs[2].command[2])
   return jobs[1], jobs[2]
end

t.test(":Zenvoy renders both lists after concurrent completion and preserves focus", function()
   local mailbox, envelope = open()
   assert(indicator(), "opening must immediately show pending work")
   t.equal(state.listing_popup.winid, vim.api.nvim_get_current_win())
   vim.cmd.Zenvoy()
   t.equal(2, #jobs)
   complete(envelope, '{"envelopes":[{"id":"1","subject":"Test email","flags":null}]}')
   assert(indicator(), "loading continues until both requests finish")
   complete(mailbox, '{"mailboxes":[{"id":"Inbox"}]}')
   assert(not indicator(), "success must stop loading")
   t.equal("Inbox", state.mailboxes[1].id)
   t.equal("1", state.envelopes[1].id)
   local lines = vim.api.nvim_buf_get_lines(state.listing_popup.bufnr, 0, -1, false)
   assert(lines[1]:find("Test email", 1, true), lines[1])
   app.close()
end)

t.test("either process failure stops loading, reports context, and cancels its sibling", function()
   for _, index in ipairs({ 1, 2 }) do
      open()
      complete(jobs[index], "", 1, "Himalaya failed")
      assert(not indicator())
      assert(notifications[1]:find("Himalaya failed", 1, true))
      t.equal(1, jobs[index == 1 and 2 or 1].kills)
      app.close()
   end
end)

t.test("malformed JSON and timeout errors release the indicator", function()
   local mailbox = open()
   complete(mailbox, "invalid-json")
   assert(not indicator())
   assert(notifications[1]:find("Invalid Himalaya JSON", 1, true))
   local _, envelope = open()
   complete(envelope, "", 124)
   assert(not indicator())
   assert(notifications[1]:find("timed out after 30000 ms", 1, true))
   app.close()
end)

t.test("q cancels both children and old callbacks cannot update a reopened session", function()
   local old_mailbox, old_envelope = open()
   for _, map in ipairs(vim.api.nvim_buf_get_keymap(state.listing_popup.bufnr, "n")) do
      if map.lhs == "q" then map.callback() end
   end
   assert(not state.is_open and not indicator())
   t.equal(1, old_mailbox.kills)
   t.equal(1, old_envelope.kills)
   vim.cmd.Zenvoy()
   local newer, mailboxes = indicator(), state.mailboxes
   complete(old_mailbox, '{"mailboxes":[{"id":"Stale"}]}')
   complete(old_envelope, '{"envelopes":[]}')
   t.equal(newer, indicator())
   assert(state.mailboxes == mailboxes)
   complete(jobs[3], '{"mailboxes":[{"id":"New"}]}')
   complete(jobs[4], '{"envelopes":[]}')
   t.equal("New", state.mailboxes[1].id)
   assert(not indicator())
   app.close()
end)

t.test("API close and external sidebar closure cancel pending work and clean windows", function()
   for _, close in ipairs({
      function() app.close() end,
      function() vim.api.nvim_win_close(state.sidebar_popup.winid, true) end,
   }) do
      local mailbox, envelope = open()
      close()
      flush()
      t.equal(1, mailbox.kills)
      t.equal(1, envelope.kills)
      assert(not state.is_open)
      t.equal(nil, state.layout)
   end
end)

t.test("spawn failures use normal error reporting", function()
   app.close()
   notifications = {}
   vim.system = function() error("cannot spawn Himalaya") end
   vim.cmd.Zenvoy()
   flush()
   assert(not indicator())
   t.equal(1, #notifications)
   assert(notifications[1]:find("cannot spawn Himalaya", 1, true))
   app.close()
   vim.system = fake_system
end)

t.test("setup options reach the process and Himalaya instances", function()
   app.close()
   jobs = {}
   app.setup({ himalaya = { executable = "/custom/himalaya", timeout = 100, page_size = 10 } })
   vim.cmd.Zenvoy()
   t.equal("/custom/himalaya", jobs[1].command[1])
   t.equal(100, jobs[1].options.timeout)
   t.equal("10", jobs[2].command[5])
   app.close()
end)

t.test("cancelling the returned request releases loading without closing the UI", function()
   app.close()
   app.setup()
   jobs = {}
   local request = app.open()
   assert(indicator())
   request:cancel()
   request:cancel()
   assert(not indicator(), "explicit cancellation must release loading")
   assert(state.is_open, "cancellation must leave the UI available")
   t.equal(1, jobs[1].kills)
   t.equal(1, jobs[2].kills)
   app.close()
end)

t.test("first-run loading works before the welcome screen is dismissed", function()
   app.close()
   app.setup()
   jobs = {}
   vim.fn.filereadable = function() return 0 end
   vim.fn.writefile = function() return 0 end
   vim.cmd.Zenvoy()
   assert(welcome and not indicator())
   complete(jobs[1], '{"mailboxes":[{"id":"Welcome"}]}')
   complete(jobs[2], '{"envelopes":[]}')
   welcome()
   assert(not indicator())
   t.equal("Welcome", state.mailboxes[1].id)
   app.close()
end)

app.close()
vim.system, vim.fn.filereadable = original_system, original_readable
vim.fn.writefile, vim.notify = original_writefile, original_notify
t.finish("loading_spec")

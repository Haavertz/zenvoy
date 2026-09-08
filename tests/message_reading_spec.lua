vim.opt.runtimepath:prepend(vim.fn.getcwd())

local t = dofile("tests/helpers.lua")
local jobs, notifications = {}, {}
vim.system = function(command, options, callback)
   local job = { command = command, options = options, exit = callback, kills = 0 }
   function job:kill() self.kills = self.kills + 1 end
   jobs[#jobs + 1] = job
   return job
end
vim.fn.filereadable = function() return 1 end
vim.notify = function(message) notifications[#notifications + 1] = message end

local app, state = require("zenvoy"), require("zenvoy.state")
dofile("plugin/zenvoy.lua")

local function flush()
   vim.wait(20, function() return false end, 5)
end

local function complete(job, output, code)
   job.exit({ code = code or 0, stdout = output or "", stderr = code and "read failed" or "" })
   flush()
end

local function mapping(popup, lhs)
   for _, map in ipairs(vim.api.nvim_buf_get_keymap(popup.bufnr, "n")) do
      if map.lhs == lhs then return map.callback end
   end
   error("missing mapping " .. lhs)
end

local function content()
   return table.concat(vim.api.nvim_buf_get_lines(state.email_popup.bufnr, 0, -1, false), "\n")
end

local function sidebar_footer()
   local border = state.sidebar_popup.border
   local row = vim.api.nvim_win_get_height(border.winid) - 1
   return vim.api.nvim_buf_get_lines(border.bufnr, row, row + 1, false)[1]
end

local function open(empty)
   app.close()
   jobs, notifications = {}, {}
   app.setup()
   vim.cmd.Zenvoy()
   complete(jobs[1], '{"mailboxes":[{"id":"Inbox"}]}')
   complete(jobs[2], empty and '{"envelopes":[]}' or vim.json.encode({ envelopes = {
      { id = "first/native-id", subject = "First email", from = { { email = "alice@example.com" } } },
      { id = "second/native-id", subject = "Second email" },
   } }))
end

local function select(row)
   vim.api.nvim_set_current_win(state.listing_popup.winid)
   vim.api.nvim_win_set_cursor(state.listing_popup.winid, { row, 0 })
   mapping(state.listing_popup, "<CR>")()
   flush() -- Let NUI finish its scheduled layout positioning between user actions.
end

local function fixture(name)
   return table.concat(vim.fn.readfile("tests/fixtures/messages/" .. name .. ".json"), "\n")
end

t.test("Enter reads the selected row and displays subject, addresses and body", function()
   open()
   select(2)
   t.equal(3, #jobs)
   t.equal("second/native-id", jobs[3].command[#jobs[3].command])
   t.equal(true, state.email_visible)
   t.equal(state.email_popup.winid, vim.api.nvim_get_current_win())
   assert(sidebar_footer():find("Loading email", 1, true), sidebar_footer())
   assert(not content():find("Loading email", 1, true), content())
   assert(not content():find("No message content", 1, true), "pending messages must not appear empty")
   assert(content():find("Subject: Second email", 1, true), content())
   complete(jobs[3], fixture("multipart"))
   assert(not sidebar_footer():find("Loading", 1, true), sidebar_footer())
   local lines = content()
   for _, text in ipairs({ "Subject: Olá", "From: Alice <alice@example.com>",
      "To: Bob <bob@example.com>, Carol <carol@example.com>",
      "Cc: Dan <dan@example.com>, Eve <eve@example.com>", "Olá, Bob!\nSecond line." }) do
      assert(lines:find(text, 1, true), lines)
   end
   local border = table.concat(vim.api.nvim_buf_get_lines(state.email_popup.border.bufnr, 0, -1, false))
   assert(border:find("Olá", 1, true), border)
   t.equal(false, vim.bo[state.email_popup.bufnr].modifiable)
   t.equal(true, vim.bo[state.email_popup.bufnr].readonly)
   t.equal(true, vim.wo[state.email_popup.winid].wrap)
end)

t.test("messages with custom transport headers and nested MIME reach the reader", function()
   open()
   select(1)
   complete(jobs[3], fixture("nested"))
   local lines = content()
   assert(lines:find("Subject: Nested MIME with encoded content", 1, true), lines)
   assert(lines:find("From: Alice <alice@example.test>", 1, true), lines)
   assert(lines:find("To: Bob <bob@example.test>", 1, true), lines)
   assert(lines:find("Olá, Bob!\nDecoded base64 body.", 1, true), lines)
   assert(not lines:find("Unable to load", 1, true), lines)
   t.equal(0, #notifications)
end)

t.test("clicking an email opens the clicked row rather than the previous cursor row", function()
   open()
   local original_mouse = vim.fn.getmousepos
   vim.fn.getmousepos = function()
      return { winid = state.listing_popup.winid, line = 2, column = 4 }
   end
   local ok, err = pcall(mapping(state.listing_popup, "<LeftRelease>"))
   vim.fn.getmousepos = original_mouse
   assert(ok, err)
   t.equal(3, #jobs)
   t.equal("second/native-id", jobs[3].command[#jobs[3].command])
end)

t.test("Enter on an empty listing does not open a pane or read a message", function()
   open(true)
   select(1)
   t.equal(false, state.email_visible)
   t.equal(2, #jobs)
end)

t.test("a newer selection cancels the previous read and ignores its late response", function()
   open()
   select(1)
   local old = jobs[3]
   select(2)
   t.equal(1, old.kills)
   complete(jobs[4], fixture("plain"))
   local current = content()
   complete(old, fixture("multipart"))
   t.equal(current, content())
end)

t.test("q cancels the read, returns to the list and allows another email to open", function()
   open()
   select(1)
   local old = jobs[3]
   mapping(state.email_popup, "q")()
   t.equal(1, old.kills)
   t.equal(false, state.email_visible)
   t.equal(state.listing_popup.winid, vim.api.nvim_get_current_win())
   assert(not sidebar_footer():find("Loading", 1, true), sidebar_footer())
   complete(old, fixture("plain"))
   t.equal(false, state.email_visible)
   select(2)
   complete(jobs[4], fixture("empty"))
   assert(content():find("No message content", 1, true), content())
end)

t.test("API and external sidebar close cancel reads and prevent updates after reopening", function()
   for _, close in ipairs({ app.close, function() vim.api.nvim_win_close(state.sidebar_popup.winid, true) end }) do
      open()
      select(1)
      local old = jobs[3]
      close()
      flush()
      t.equal(1, old.kills)
      open()
      select(2)
      local before = content()
      complete(old, fixture("plain"))
      t.equal(before, content())
   end
end)

t.test("process errors, invalid JSON and timeouts appear in the pane and allow retry", function()
   for _, failure in ipairs({ { "", 1 }, { "invalid-json" }, { "", 124 } }) do
      open()
      select(1)
      complete(jobs[3], failure[1], failure[2])
      assert(content():find("Unable to load email", 1, true), content())
      assert(not content():find("Loading email", 1, true), content())
      assert(not sidebar_footer():find("Loading", 1, true), sidebar_footer())
      t.equal(1, #notifications)
      select(1)
      complete(jobs[4], fixture("plain"))
      assert(content():find("Hello, Bob!", 1, true), content())
   end
end)

t.test("the configured executable and timeout also apply to message reads", function()
   app.close()
   jobs = {}
   app.setup({ himalaya = { executable = "/custom/himalaya", timeout = 1234 } })
   vim.cmd.Zenvoy()
   complete(jobs[1], '{"mailboxes":[]}')
   complete(jobs[2], '{"envelopes":[{"id":"custom","subject":"Custom"}]}')
   select(1)
   t.equal("/custom/himalaya", jobs[3].command[1])
   t.equal(1234, jobs[3].options.timeout)
end)

t.test("spawn failure during a read is displayed and clears loading", function()
   app.close()
   jobs = {}
   local original_system = vim.system
   vim.system = function(command, ...)
      if command[2] == "message" then error("cannot spawn reader") end
      return original_system(command, ...)
   end
   app.setup()
   vim.cmd.Zenvoy()
   complete(jobs[1], '{"mailboxes":[]}')
   complete(jobs[2], '{"envelopes":[{"id":"1","subject":"Test"}]}')
   select(1)
   vim.system = original_system
   assert(content():find("cannot spawn reader", 1, true), content())
   assert(not content():find("Loading email", 1, true))
end)

t.test("header line breaks are flattened and body line breaks are preserved", function()
   open()
   select(1)
   local value = vim.json.decode(fixture("plain"))
   value.parts[1].headers[3].value.Text = "A subject\nwith a newline"
   value.parts[1].headers[1].value.Address.List[1].name = "Alice\r\nSmith"
   value.parts[1].body.Text = "First line\r\n\r\nSecond line"
   complete(jobs[3], vim.json.encode(value))
   assert(content():find("Subject: A subject with a newline", 1, true), content())
   assert(content():find("From: Alice  Smith <alice@example.com>", 1, true), content())
   assert(content():find("First line\n\nSecond line", 1, true), content())
end)

app.close()
t.finish("message_reading_spec")

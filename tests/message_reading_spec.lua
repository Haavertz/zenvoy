vim.opt.runtimepath:prepend(vim.fn.getcwd())

local t = dofile("tests/helpers.lua")
-- Wide enough that headers do not wrap.
vim.o.columns, vim.o.lines = 220, 50
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

-- The bottom border that shows activity: the email's while it covers the window,
-- otherwise the folders'.
local function footer()
   local popup = state.sidebar_popup.winid and state.sidebar_popup or state.email_popup
   local lines = vim.api.nvim_buf_get_lines(popup.border.bufnr, 0, -1, false)
   return lines[#lines]
end

local function rect(winid)
   local row, col = unpack(vim.api.nvim_win_get_position(winid))
   return { row, col, vim.api.nvim_win_get_width(winid), vim.api.nvim_win_get_height(winid) }
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

local function press(lhs)
   mapping(state.email_popup, lhs)()
   flush()
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
   -- The email opens below the list, and the folders' border shows the activity.
   assert(rect(state.email_popup.winid)[1] > rect(state.listing_popup.winid)[1], "the email goes below the list")
   assert(footer():find("Loading email", 1, true), footer())
   assert(not content():find("Loading email", 1, true), content())
   assert(not content():find("No message content", 1, true), "pending messages must not appear empty")
   assert(content():find("Subject:  Second email", 1, true), content())
   local value = vim.json.decode(fixture("multipart"))
   value.parts[3].body.Html = "<p>Olá, <b>Bob</b>!</p><p>Formatted <a href='https://example.com/x'>version</a></p>"
   complete(jobs[3], vim.json.encode(value))
   assert(not footer():find("Loading", 1, true), footer())
   local lines = content()
   for _, text in ipairs({ "Subject:  Olá", "From:     Alice <alice@example.com>",
      "To:       Bob <bob@example.com>, Carol <carol@example.com>",
      "Cc:       Dan <dan@example.com>, Eve <eve@example.com>", "Date:     ",
      "Olá, Bob!\n\nFormatted version" }) do
      assert(lines:find(text, 1, true), lines)
   end
   -- The HTML alternative is the default view; T switches to the text/plain part.
   mapping(state.email_popup, "T")()
   lines = content()
   assert(lines:find("Olá, Bob!\nSecond line.", 1, true), lines)
   assert(not lines:find("Formatted version", 1, true), lines)
   mapping(state.email_popup, "T")()
   assert(content():find("Formatted version", 1, true), content())
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
   assert(lines:find("Subject:  Nested MIME with encoded content", 1, true), lines)
   assert(lines:find("From:     Alice <alice@example.test>", 1, true), lines)
   assert(lines:find("To:       Bob <bob@example.test>", 1, true), lines)
   assert(lines:find("Olá, Bob!\n\nHTML alternative\n\n[Image: Test logo]", 1, true), lines)
   -- The inline logo is shown in place; only the real attachment is listed.
   assert(lines:find("1 attachment\n  sample.bin  BIN · 50 B", 1, true), lines)
   assert(not lines:find("Unable to load", 1, true), lines)
   t.equal(0, #notifications)
   mapping(state.email_popup, "T")()
   assert(content():find("Olá, Bob!\nDecoded base64 body.", 1, true), content())
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
   t.equal(1, vim.api.nvim_win_get_cursor(state.listing_popup.winid)[1])
   assert(not footer():find("Loading", 1, true), footer())
   complete(old, fixture("plain"))
   t.equal(false, state.email_visible)
   select(2)
   complete(jobs[4], fixture("empty"))
   assert(content():find("No message content", 1, true), content())
end)

t.test("API and external closes cancel reads and prevent updates after reopening", function()
   local closes = {
      app.close,
      function() vim.api.nvim_win_close(state.sidebar_popup.winid, true) end,
      -- Over the whole window the email is the only pane: closing it closes Zenvoy.
      function()
         press("z")
         vim.api.nvim_win_close(state.email_popup.winid, true)
      end,
   }
   for _, close in ipairs(closes) do
      app.close()
      local windows = #vim.api.nvim_list_wins()
      open()
      select(1)
      local old = jobs[3]
      close()
      flush()
      t.equal(false, state.is_open)
      t.equal(windows, #vim.api.nvim_list_wins())
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
      assert(not footer():find("Loading", 1, true), footer())
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
   assert(content():find("Subject:  A subject with a newline", 1, true), content())
   assert(content():find("From:     Alice Smith <alice@example.com>", 1, true), content())
   assert(content():find("First line\n\nSecond line", 1, true), content())
end)

-- The separator below the header: a line made of rule characters only.
local function rule()
   for _, line in ipairs(vim.api.nvim_buf_get_lines(state.email_popup.bufnr, 0, -1, false)) do
      if line ~= "" and line:gsub("─", "") == "" then return line end
   end
end

local function text_width()
   local width = 0
   for _, line in ipairs(vim.api.nvim_buf_get_lines(state.email_popup.bufnr, 0, -1, false)) do
      if line:find("A long paragraph", 1, true) then width = math.max(width, vim.api.nvim_strwidth(line)) end
   end
   return width
end

-- Words wrap whole, so the longest line is at most one word short of the width.
local function fills(width, text)
   assert(text <= width and text > width - #"paragraph ", text .. " fills " .. width)
end

local function long_email()
   local value = vim.json.decode(fixture("multipart"))
   value.parts[3].body.Html = "<p>" .. string.rep("A long paragraph of formatted text. ", 60) .. "</p>"
   return vim.json.encode(value)
end

t.test("the separators span the whole pane while the text keeps reader.max_width", function()
   open()
   select(1)
   complete(jobs[3], long_email())
   local pane = vim.api.nvim_win_get_width(state.email_popup.winid)
   assert(pane > 100, "the test needs a pane wider than reader.max_width")
   t.equal(pane, vim.api.nvim_strwidth(rule()))
   fills(100, text_width())
   press("z")
   pane = vim.api.nvim_win_get_width(state.email_popup.winid)
   t.equal(pane, vim.api.nvim_strwidth(rule()))
   fills(100, text_width())
end)

t.test("z shows the email over the whole window and back; the next email opens below the list", function()
   open()
   app.close()
   app.setup({ reader = { max_width = 0 } }) -- Lay the text out across the whole pane.
   vim.cmd.Zenvoy()
   complete(jobs[#jobs - 1], '{"mailboxes":[{"id":"Inbox"}]}')
   complete(jobs[#jobs], '{"envelopes":[{"id":"first"},{"id":"second"}]}')
   select(1)
   assert(footer():find("Loading email", 1, true), footer())
   press("z")
   -- The email covers the whole Zenvoy window, and its own border shows the activity.
   t.equal(state.email_popup.winid, vim.api.nvim_get_current_win())
   t.equal(nil, state.sidebar_popup.winid)
   t.equal(nil, state.listing_popup.winid)
   t.equal(rect(state.layout.winid), rect(state.email_popup.border.winid))
   assert(footer():find("Loading email", 1, true), footer())
   complete(jobs[#jobs], long_email())
   assert(not footer():find("Loading", 1, true), footer())
   local full = text_width()
   fills(vim.api.nvim_win_get_width(state.email_popup.winid) - 1, full)
   local count = vim.api.nvim_buf_line_count(state.email_popup.bufnr)
   vim.api.nvim_win_set_cursor(state.email_popup.winid, { count, 0 })

   press("z")
   t.equal(state.email_popup.winid, vim.api.nvim_get_current_win())
   assert(state.sidebar_popup.winid and state.listing_popup.winid, "z again shows the folders and the list")
   assert(rect(state.email_popup.winid)[1] > rect(state.listing_popup.winid)[1], "the email goes below the list")
   -- Laid out again for the narrower pane, near the same place in the text.
   local split = text_width()
   fills(vim.api.nvim_win_get_width(state.email_popup.winid) - 1, split)
   assert(split < full, split .. " < " .. full)
   count = vim.api.nvim_buf_line_count(state.email_popup.bufnr)
   assert(vim.api.nvim_win_get_cursor(state.email_popup.winid)[1] > count / 2, "the reading position is kept")

   -- Over the whole window, q returns to the list; the next email opens below it.
   press("z")
   press("q")
   t.equal(state.listing_popup.winid, vim.api.nvim_get_current_win())
   t.equal(1, vim.api.nvim_win_get_cursor(state.listing_popup.winid)[1])
   select(2)
   assert(state.listing_popup.winid, "the next email opens below the list")
   t.equal(state.email_popup.winid, vim.api.nvim_get_current_win())
end)

t.test("s from an email over the whole window returns to the list with the folders focused", function()
   open()
   select(2)
   press("z")
   press("s")
   t.equal(false, state.email_visible)
   t.equal(state.sidebar_popup.winid, vim.api.nvim_get_current_win())
end)

app.close()
t.finish("message_reading_spec")

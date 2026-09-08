vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local jobs, notices = {}, {}
vim.system = function(command, options, callback)
   local job = { command = command, options = options, exit = callback, kills = 0 }
   function job:kill() self.kills = self.kills + 1 end
   jobs[#jobs + 1] = job
   return job
end
vim.fn.filereadable = function() return 1 end
vim.notify = function(text) notices[#notices + 1] = text end
local app, state = require("zenvoy"), require("zenvoy.state")

local function flush(ms)
   vim.wait(ms or 25, function() return false end, 5)
end
local function complete(job, value, code)
   job.exit({ code = code or 0, stdout = type(value) == "table" and vim.json.encode(value) or value,
      stderr = code and "mailbox unavailable" or "" })
   flush()
end
local function mapping(popup, key)
   for _, map in ipairs(vim.api.nvim_buf_get_keymap(popup.bufnr, "n")) do
      if map.lhs == key then return map.callback end
   end
   error("missing mapping " .. key)
end
local function mailbox_arg(job)
   for index, arg in ipairs(job.command) do
      if arg == "--mailbox" then return job.command[index + 1] end
      if arg:sub(1, 10) == "--mailbox=" then return arg:sub(11) end
   end
end
local function move(row)
   vim.api.nvim_set_current_win(state.sidebar_popup.winid)
   vim.api.nvim_win_set_cursor(state.sidebar_popup.winid, { row, 0 })
   vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.sidebar_popup.bufnr })
end
local function open(opts)
   app.close()
   jobs, notices = {}, {}
   app.setup(opts)
   app.open()
   complete(jobs[1], { mailboxes = { { id = "native/inbox" }, { id = "native/archive" }, { id = "native/sent" } } })
   complete(jobs[2], { envelopes = { { id = "shared-id", subject = "Original", flags = {} } } })
   flush(180)
   t.equal(2, #jobs) -- Rendering must not select the first row implicitly.
end
local function footer()
   local border = state.sidebar_popup.border
   return table.concat(vim.api.nvim_buf_get_lines(border.bufnr, 0, -1, false), "\n")
end

t.test("s focuses sidebar, navigation loads its native mailbox, Enter returns to list", function()
   open()
   mapping(state.listing_popup, "s")()
   t.equal(state.sidebar_popup.winid, vim.api.nvim_get_current_win())
   move(2)
   t.equal(0, #state.envelopes) -- Old IDs must not remain usable during the debounce.
   flush(180)
   t.equal(3, #jobs)
   t.equal("native/archive", mailbox_arg(jobs[3]))
   t.equal("native/archive", state.current_folder)
   t.equal(1, state.current_page)
   complete(jobs[3], { envelopes = { { id = "archive-id", subject = "Archived" } } })
   t.equal(state.sidebar_popup.winid, vim.api.nvim_get_current_win())
   t.equal("archive-id", state.envelopes[1].id)
   move(2)
   flush(180)
   t.equal(3, #jobs)
   mapping(state.sidebar_popup, "<CR>")()
   t.equal(state.listing_popup.winid, vim.api.nvim_get_current_win())
end)

t.test("a mailbox change cancels an open read and late listing/read results stay ignored", function()
   open()
   mapping(state.listing_popup, "<CR>")()
   local old_read = jobs[3]
   assert(vim.tbl_contains(old_read.command, "--seen"), vim.inspect(old_read.command))
   mapping(state.email_popup, "s")()
   move(2)
   t.equal(false, state.email_visible)
   t.equal(1, old_read.kills)
   flush(180)
   local archive = jobs[4]
   move(3)
   t.equal(1, archive.kills)
   flush(180)
   local sent = jobs[5]
   complete(sent, { envelopes = { { id = "shared-id", subject = "Sent message" } } })
   complete(archive, { envelopes = { { id = "stale", subject = "Stale" } } })
   complete(old_read, table.concat(vim.fn.readfile("tests/fixtures/messages/plain.json"), "\n"))
   t.equal("Sent message", state.envelopes[1].subject)
   t.equal(false, state.email_visible)
   mapping(state.sidebar_popup, "<CR>")()
   mapping(state.listing_popup, "<CR>")()
   t.equal("native/sent", mailbox_arg(jobs[6]))
   t.equal("shared-id", jobs[6].command[#jobs[6].command])
end)

t.test("empty and failed mailboxes clear activity and Enter retries a failure", function()
   open()
   move(2)
   flush(180)
   complete(jobs[3], "", 1)
   t.equal(0, #state.envelopes)
   assert(not footer():find("Loading", 1, true), footer())
   assert(notices[1]:find("mailbox unavailable", 1, true))
   mapping(state.sidebar_popup, "<CR>")()
   t.equal(4, #jobs)
   complete(jobs[4], { envelopes = {} })
   t.equal({ "" }, vim.api.nvim_buf_get_lines(state.listing_popup.bufnr, 0, -1, false))
   assert(not footer():find("Loading", 1, true), footer())
end)

t.test("successful reads update seen once, preserve other flags and the listing cursor", function()
   open()
   require("zenvoy.ui").set_envelopes({
      { id = "first", flags = {} }, { id = "second", flags = { "flagged" } },
   })
   vim.api.nvim_win_set_cursor(state.listing_popup.winid, { 2, 0 })
   mapping(state.listing_popup, "<CR>")()
   local fixture = table.concat(vim.fn.readfile("tests/fixtures/messages/plain.json"), "\n")
   complete(jobs[3], fixture)
   t.equal(2, vim.api.nvim_win_get_cursor(state.listing_popup.winid)[1])
   t.equal({ "flagged", "seen" }, state.envelopes[2].flags)
   mapping(state.email_popup, "q")()
   mapping(state.listing_popup, "<CR>")()
   complete(jobs[4], fixture)
   t.equal({ "flagged", "seen" }, state.envelopes[2].flags)
   mapping(state.email_popup, "q")()
   vim.api.nvim_win_set_cursor(state.listing_popup.winid, { 1, 0 })
   mapping(state.listing_popup, "<CR>")()
   complete(jobs[5], "", 1)
   t.equal({}, state.envelopes[1].flags)
end)

t.test("close cancels mailbox requests and debounce timers across sessions", function()
   open()
   move(2)
   flush(180)
   local old = jobs[3]
   app.close()
   t.equal(1, old.kills)
   open()
   complete(old, { envelopes = { { id = "stale" } } })
   t.equal("Original", state.envelopes[1].subject)
   move(2)
   app.close()
   flush(180)
   t.equal(2, #jobs)
end)

t.test("sidebar focus can be remapped and disabled", function()
   open({ keymaps = { s = false, z = "focus_sidebar" } })
   t.equal(false, pcall(mapping, state.listing_popup, "s"))
   mapping(state.listing_popup, "z")()
   t.equal(state.sidebar_popup.winid, vim.api.nvim_get_current_win())
end)

app.close()
t.finish("mailbox_navigation_spec")

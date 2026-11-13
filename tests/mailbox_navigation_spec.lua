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
local function open(opts, envelopes)
   app.close()
   jobs, notices = {}, {}
   app.setup(opts)
   app.open()
   complete(jobs[1], { mailboxes = { { id = "native/inbox" }, { id = "native/archive" }, { id = "native/sent" } } })
   complete(jobs[2], { envelopes = envelopes or { { id = "shared-id", subject = "Original", flags = {} } } })
   flush(180)
   t.equal(2, #jobs) -- Rendering must not select the first row implicitly.
end
local function footer()
   local border = state.sidebar_popup.border
   return table.concat(vim.api.nvim_buf_get_lines(border.bufnr, 0, -1, false), "\n")
end
local function page_arg(job)
   for index, arg in ipairs(job.command) do
      if arg == "--page" then return job.command[index + 1] end
   end
end
local function title()
   return vim.api.nvim_buf_get_lines(state.listing_popup.border.bufnr, 0, 1, false)[1]
end
local function ids()
   local result = {}
   for index, envelope in ipairs(state.envelopes) do result[index] = envelope.id end
   return result
end
local function emails(prefix, count)
   local result = {}
   for index = 1, count do result[index] = { id = prefix .. index, subject = prefix .. index, flags = {} } end
   return result
end
-- Two emails a page: full first and second pages, and a third with one email.
local function open_pages()
   open({ himalaya = { page_size = 2 } }, emails("a", 2))
   vim.api.nvim_set_current_win(state.listing_popup.winid)
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
   -- The list is redrawn behind an email over the whole window; q shows the same row.
   mapping(state.email_popup, "z")()
   mapping(state.email_popup, "q")()
   t.equal(2, vim.api.nvim_win_get_cursor(state.listing_popup.winid)[1])
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

t.test("n and N page through the list, which stays until the next page arrives", function()
   open_pages()
   assert(title():find("Emails (2) · Page 1", 1, true), title())
   mapping(state.listing_popup, "n")()
   t.equal(3, #jobs)
   t.equal("2", page_arg(jobs[3]))
   t.equal(nil, mailbox_arg(jobs[3]))
   t.equal({ "a1", "a2" }, ids())
   assert(footer():find("Loading page 2", 1, true), footer())
   assert(title():find("Page 1", 1, true), title())
   complete(jobs[3], { envelopes = emails("b", 2) })
   t.equal(2, state.current_page)
   t.equal({ "b1", "b2" }, ids())
   assert(title():find("Emails (2) · Page 2", 1, true), title())
   assert(not footer():find("Loading", 1, true), footer())

   -- A full page may be the last: an empty next page keeps it.
   vim.api.nvim_win_set_cursor(state.listing_popup.winid, { 2, 0 })
   mapping(state.listing_popup, "n")()
   t.equal("3", page_arg(jobs[4]))
   complete(jobs[4], { envelopes = {} })
   t.equal(2, state.current_page)
   t.equal({ "b1", "b2" }, ids())
   t.equal({ "Zenvoy: this is the last page" }, notices)
   t.equal(2, vim.api.nvim_win_get_cursor(state.listing_popup.winid)[1])

   mapping(state.listing_popup, "N")()
   t.equal(nil, page_arg(jobs[5]))
   complete(jobs[5], { envelopes = emails("a", 2) })
   t.equal(1, state.current_page)
   t.equal({ "a1", "a2" }, ids())
   t.equal(1, vim.api.nvim_win_get_cursor(state.listing_popup.winid)[1])
   mapping(state.listing_popup, "N")()
   t.equal(5, #jobs)
   t.equal("Zenvoy: this is the first page", notices[2])
end)

t.test("a short page is the last, n then N stays, and N twice goes back two pages", function()
   open_pages()
   mapping(state.listing_popup, "n")()
   mapping(state.listing_popup, "N")()
   t.equal(1, jobs[3].kills)
   t.equal(3, #jobs)
   t.equal(1, state.current_page)
   assert(not footer():find("Loading", 1, true), footer())

   mapping(state.listing_popup, "n")()
   mapping(state.listing_popup, "n")() -- Page 3 waits for page 2.
   t.equal(4, #jobs)
   complete(jobs[4], { envelopes = emails("b", 2) })
   mapping(state.listing_popup, "n")()
   complete(jobs[5], { envelopes = emails("c", 1) })
   t.equal(3, state.current_page)
   mapping(state.listing_popup, "n")()
   t.equal(5, #jobs)
   t.equal({ "Zenvoy: this is the last page" }, notices)

   mapping(state.listing_popup, "N")()
   mapping(state.listing_popup, "N")()
   t.equal(1, jobs[6].kills)
   t.equal(nil, page_arg(jobs[7]))
   complete(jobs[6], { envelopes = emails("stale", 2) })
   complete(jobs[7], { envelopes = emails("a", 2) })
   t.equal(1, state.current_page)
   t.equal({ "a1", "a2" }, ids())
end)

t.test("pages keep the folder and an open email; folders and opening an email cancel a page", function()
   open_pages()
   move(2)
   flush(180)
   complete(jobs[3], { envelopes = emails("archive", 2) })
   mapping(state.sidebar_popup, "<CR>")()
   mapping(state.listing_popup, "n")()
   t.equal("native/archive", mailbox_arg(jobs[4]))
   t.equal("2", page_arg(jobs[4]))
   -- Another folder starts again at its first page.
   move(3)
   t.equal(1, jobs[4].kills)
   t.equal(1, state.current_page)
   assert(title():find("Page 1", 1, true), title())
   flush(180)
   complete(jobs[5], { envelopes = emails("sent", 2) })

   mapping(state.sidebar_popup, "<CR>")()
   mapping(state.listing_popup, "n")()
   mapping(state.listing_popup, "<CR>")()
   t.equal(1, jobs[6].kills)
   t.equal("sent1", jobs[7].command[#jobs[7].command])
   complete(jobs[7], table.concat(vim.fn.readfile("tests/fixtures/messages/plain.json"), "\n"))
   t.equal(1, state.current_page)

   -- The email stays open below the list while the list changes page.
   vim.api.nvim_set_current_win(state.listing_popup.winid)
   mapping(state.listing_popup, "n")()
   complete(jobs[8], { envelopes = emails("older", 2) })
   t.equal(2, state.current_page)
   t.equal(true, state.email_visible)
   t.equal("sent1", state.open_envelope.id)
end)

t.test("a failed page keeps the shown one, and page keys stay in the email list", function()
   open_pages()
   mapping(state.listing_popup, "n")()
   complete(jobs[3], "", 1)
   t.equal(1, state.current_page)
   t.equal({ "a1", "a2" }, ids())
   assert(notices[1]:find("mailbox unavailable", 1, true), notices[1])
   assert(not footer():find("Loading", 1, true), footer())
   for _, popup in ipairs({ state.sidebar_popup, state.email_popup }) do
      t.equal(false, pcall(mapping, popup, "n"))
      t.equal(false, pcall(mapping, popup, "N"))
   end
   t.equal(false, pcall(mapping, state.listing_popup, "<C-N>"))
end)

app.close()
t.finish("mailbox_navigation_spec")

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local Reader = require("zenvoy.ui.reader")

-- Controller ------------------------------------------------------------------

local function controller(overrides)
   local observed = { choices = {}, inputs = {}, opened = {}, downloads = {}, notices = {}, copied = {} }
   local reader = Reader.new(vim.tbl_extend("force", {
      choose = function(items, options, callback)
         observed.choices[#observed.choices + 1] = { items = items, prompt = options.prompt, callback = callback }
      end,
      input = function(options, callback) observed.inputs[#observed.inputs + 1] = { options = options, callback = callback } end,
      open = function(target)
         observed.opened[#observed.opened + 1] = target
         return {}
      end,
      download = function(id, mailbox, ids, directory, callback)
         observed.downloads[#observed.downloads + 1] = { id = id, mailbox = mailbox, ids = ids, directory = directory,
            callback = callback }
      end,
      notify = function(message) observed.notices[#observed.notices + 1] = message end,
      copy = function(text) observed.copied[#observed.copied + 1] = text end,
      temporary_directory = function() return "/tmp/zenvoy-open" end,
      download_dir = function() return "/home/me/Downloads" end,
   }, overrides or {}))
   return reader, observed
end

local context = { id = "native/id", mailbox = "Archive" }
local report = { id = "7", name = "report.pdf", size = 2048 }

t.test("link menu shows the real destination before opening or copying", function()
   local reader, observed = controller()
   reader:link_menu("https://example.com/path")
   t.equal({ "Open link", "Copy link", "Cancel" }, observed.choices[1].items)
   t.equal("Link: https://example.com/path", observed.choices[1].prompt)
   observed.choices[1].callback("Open link")
   t.equal({ "https://example.com/path" }, observed.opened)
   reader:link_menu("mailto:a@b.example")
   observed.choices[2].callback("Copy link")
   t.equal({ "mailto:a@b.example" }, observed.copied)
   reader:open_link("javascript:alert(1)")
   t.equal(1, #observed.opened)
   assert(observed.notices[#observed.notices]:find("only http", 1, true))
end)

t.test("save downloads by part ID to the configured directory and reports the path", function()
   local reader, observed = controller()
   reader:save(report, context)
   t.equal({ id = "native/id", mailbox = "Archive", ids = { "7" }, directory = "/home/me/Downloads" },
      { id = observed.downloads[1].id, mailbox = observed.downloads[1].mailbox, ids = observed.downloads[1].ids,
         directory = observed.downloads[1].directory })
   observed.downloads[1].callback(nil, { { id = "7", path = "/home/me/Downloads/report.pdf" } })
   t.equal("Zenvoy: saved /home/me/Downloads/report.pdf", observed.notices[1])
   reader:save(report, context)
   observed.downloads[2].callback("No attachment with id 7")
   assert(observed.notices[2]:find("No attachment with id 7", 1, true))
end)

t.test("attachment menu offers open, save and save-to with the size", function()
   local reader, observed = controller()
   reader:attachment_menu(report, context)
   t.equal({ "Open", "Save", "Save to…", "Cancel" }, observed.choices[1].items)
   t.equal("report.pdf (2 KB)", observed.choices[1].prompt)
   observed.choices[1].callback("Save to…")
   t.equal("dir", observed.inputs[1].options.completion)
   observed.inputs[1].callback("/tmp/elsewhere")
   t.equal("/tmp/elsewhere", observed.downloads[1].directory)
   observed.choices[1].callback("Open")
   t.equal("/tmp/zenvoy-open", observed.downloads[2].directory)
   observed.downloads[2].callback(nil, { { path = "/tmp/zenvoy-open/report.pdf" } })
   t.equal({ "/tmp/zenvoy-open/report.pdf" }, observed.opened)
end)

t.test("opening executable types needs an explicit confirmation", function()
   local reader, observed = controller()
   reader:open_attachment({ id = "3", name = "invoice\226\128\174fdp.exe" }, context)
   t.equal({ "Cancel", "Open anyway" }, observed.choices[1].items)
   assert(observed.choices[1].prompt:find("invoicefdp.exe can run code", 1, true), observed.choices[1].prompt)
   observed.choices[1].callback("Cancel")
   t.equal(0, #observed.downloads)
   reader:open_attachment({ id = "3", name = "setup.exe" }, context)
   observed.choices[2].callback("Open anyway")
   t.equal(1, #observed.downloads)
end)

t.test("saving without a selected attachment asks which one", function()
   local reader, observed = controller()
   reader:save_any({}, context)
   assert(observed.notices[1]:find("no attachments", 1, true))
   reader:save_any({ report }, context)
   t.equal(1, #observed.downloads)
   reader:save_any({ report, { id = "8", name = "b.txt" } }, context)
   t.equal({ "report.pdf", "b.txt", "All attachments" }, observed.choices[1].items)
   observed.choices[1].callback("All attachments", 3)
   t.equal(3, #observed.downloads)
end)

-- Message pane integration ---------------------------------------------------------

vim.o.columns, vim.o.lines = 200, 60
local jobs, notifications, opened = {}, {}, {}
vim.system = function(command, options, callback)
   local job = { command = command, options = options, exit = callback, kills = 0 }
   function job:kill() self.kills = self.kills + 1 end
   jobs[#jobs + 1] = job
   return job
end
vim.fn.filereadable = function() return 1 end
vim.notify = function(message) notifications[#notifications + 1] = message end
-- Menus use Zenvoy's own dialog, never the global picker.
vim.ui.select = function() error("vim.ui.select must not be used") end
vim.ui.open = function(target)
   opened[#opened + 1] = target
   return {}
end
local app, state = require("zenvoy"), require("zenvoy.state")

local function flush() vim.wait(20, function() return false end, 5) end
local function complete(job, output)
   job.exit({ code = 0, stdout = output or "", stderr = "" })
   flush()
end
local function press(lhs)
   for _, map in ipairs(vim.api.nvim_buf_get_keymap(state.email_popup.bufnr, "n")) do
      if map.lhs == lhs then return map.callback() end
   end
   error("missing mapping " .. lhs)
end
local function cursor() return vim.api.nvim_win_get_cursor(state.email_popup.winid) end
local function line() return vim.api.nvim_get_current_line() end
local function status()
   local border = state.email_popup.border
   return vim.api.nvim_buf_get_lines(border.bufnr, -2, -1, false)[1]
end
local function corners(popup)
   local lines = vim.api.nvim_buf_get_lines(popup.border.bufnr, 0, -1, false)
   return { lines[1]:sub(1, 3), lines[#lines]:sub(1, 3) }
end

local function message_json()
   local value = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/messages/nested.json"), "\n"))
   value.parts[5].body.Html = [[<p>Hi <a href="https://example.com/a">first</a> and
      <a href="https://example.com/b">second</a></p><p><img src="cid:logo" alt="Logo"></p>
      <div>Carol wrote:</div><blockquote><p>one</p><p>two</p><p>three</p></blockquote>]]
   return vim.json.encode(value)
end

local function open_message()
   app.close()
   jobs, notifications, opened = {}, {}, {}
   app.setup({ attachments = { download_dir = "/tmp/zenvoy-downloads" } })
   app.open()
   complete(jobs[1], '{"mailboxes":[{"id":"Inbox"}]}')
   complete(jobs[2], '{"envelopes":[{"id":"msg-1","subject":"Nested"}]}')
   vim.api.nvim_set_current_win(state.listing_popup.winid)
   for _, map in ipairs(vim.api.nvim_buf_get_keymap(state.listing_popup.bufnr, "n")) do
      if map.lhs == "<CR>" then map.callback() end
   end
   flush()
   complete(jobs[3], message_json())
end

t.test("Tab walks links, inline images and attachments while the border shows the target", function()
   open_message()
   for _, popup in ipairs({ state.sidebar_popup, state.listing_popup, state.email_popup }) do
      t.equal({ "┌", "└" }, corners(popup))
   end
   press("<Tab>")
   t.equal("first", line():sub(cursor()[2] + 1, cursor()[2] + 5))
   assert(status():find("→ https://example.com/a", 1, true), status())
   press("<Tab>")
   t.equal("second", line():sub(cursor()[2] + 1, cursor()[2] + 6))
   press("<Tab>")
   t.equal("[Image: Logo]", line())
   assert(status():find("show image", 1, true), status())
   press("<Tab>")
   assert(line():find("sample.bin", 1, true), line())
   assert(status():find("S save", 1, true), status())
   press("<Tab>")
   t.equal("first", line():sub(cursor()[2] + 1, cursor()[2] + 5))
   press("<S-Tab>")
   assert(line():find("sample.bin", 1, true), line())
end)

t.test("Enter and gx open links only after an explicit action", function()
   open_message()
   press("<Tab>")
   press("<CR>")
   local menu = assert(t.dialog(), "Enter should ask before opening a link")
   t.equal("Link: https://example.com/a", vim.trim(menu.lines[1]))
   t.equal({ "Open link", "Copy link", "Cancel" }, menu.labels)
   t.equal({}, opened)
   t.answer("Open link")
   t.equal({ "https://example.com/a" }, opened)
   -- The dialog returns to the message, so its keys keep working.
   t.equal(state.email_popup.winid, vim.api.nvim_get_current_win())
   press("<Tab>")
   press("gx")
   t.equal({ "https://example.com/a", "https://example.com/b" }, opened)
   -- Closing Zenvoy also closes an open menu without acting on it.
   press("<CR>")
   assert(t.dialog(), "Enter should ask again")
   app.close()
   t.equal(nil, t.dialog())
   t.equal(2, #opened)
end)

t.test("S and Open download the attachment under the cursor through Himalaya", function()
   open_message()
   local count = #jobs
   vim.api.nvim_win_set_cursor(state.email_popup.winid, { vim.api.nvim_buf_line_count(state.email_popup.bufnr), 0 })
   press("S")
   t.equal({ "himalaya", "attachment", "download", "--dir=/tmp/zenvoy-downloads", "--json", "--log-level", "off",
      "--", "msg-1", "7" }, jobs[count + 1].command)
   complete(jobs[count + 1], '{"attachments":[{"id":"7","size":50,"inline":false,"path":"/tmp/zenvoy-downloads/sample.bin"}]}')
   t.equal("Zenvoy: saved /tmp/zenvoy-downloads/sample.bin", notifications[#notifications])
   press("<CR>")
   t.equal({ "Open", "Save", "Save to…", "Cancel" }, assert(t.dialog()).labels)
   t.answer("Open")
   -- sample.bin is an executable type: opening it needs a second confirmation.
   local warning = assert(t.dialog(), "opening an executable type should ask again")
   t.equal({ "Cancel", "Open anyway" }, warning.labels)
   t.equal("Cancel", warning.focus)
   t.equal(count + 1, #jobs)
   t.answer("Open anyway")
   local download = jobs[count + 2]
   assert(not vim.tbl_contains(download.command, "--dir=/tmp/zenvoy-downloads"), vim.inspect(download.command))
   complete(download, '{"attachments":[{"id":"7","size":50,"inline":false,"path":"/tmp/nvim/x/sample.bin"}]}')
   t.equal({ "/tmp/nvim/x/sample.bin" }, opened)
end)

t.test("I renders the inline image marker under the cursor, T switches views, and quotes fold", function()
   open_message()
   local lines = vim.api.nvim_buf_get_lines(state.email_popup.bufnr, 0, -1, false)
   for row, text in ipairs(lines) do
      if text == "[Image: Logo]" then vim.api.nvim_win_set_cursor(state.email_popup.winid, { row, 3 }) end
   end
   press("I")
   -- image.nvim is not installed in tests: the marker is recognized and explained.
   assert(notifications[#notifications]:find("image.nvim", 1, true), notifications[#notifications])
   local folded = false
   vim.api.nvim_win_call(state.email_popup.winid, function()
      for row = 1, #lines do
         if vim.fn.foldclosed(row) ~= -1 then folded = true end
      end
   end)
   t.equal(true, folded)
   press("T")
   local plain = table.concat(vim.api.nvim_buf_get_lines(state.email_popup.bufnr, 0, -1, false), "\n")
   assert(plain:find("Olá, Bob!\nDecoded base64 body.", 1, true), plain)
   assert(plain:find("[Image 1: logo.png]  Press I to render", 1, true), plain)
end)

t.test("Enter expands a folded quote and folds it again from its text", function()
   open_message()
   local winid = state.email_popup.winid
   local function closed(row)
      return vim.api.nvim_win_call(winid, function() return vim.fn.foldclosed(row) end)
   end
   local start
   for row = 1, vim.api.nvim_buf_line_count(state.email_popup.bufnr) do
      if closed(row) == row then start = row break end
   end
   assert(start, "the quote should start folded")
   local label = vim.api.nvim_win_call(winid, function() return vim.fn.foldtextresult(start) end)
   assert(label:find("(Enter to expand)", 1, true), label)
   vim.api.nvim_win_set_cursor(winid, { start, 0 })
   press("<CR>")
   t.equal(nil, t.dialog())
   t.equal(-1, closed(start))
   vim.api.nvim_win_set_cursor(winid, { start + 2, 0 })
   press("<CR>")
   t.equal(start, closed(start + 2))
   -- Outside quotes, Enter without a link or file does nothing.
   vim.api.nvim_win_set_cursor(winid, { 1, 0 })
   press("<CR>")
   t.equal(nil, t.dialog())
   t.equal(start, closed(start))
end)

app.close()
t.finish("reader_spec")

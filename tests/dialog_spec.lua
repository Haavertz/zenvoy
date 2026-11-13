vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local dialog = require("zenvoy.ui.dialog")

vim.o.columns, vim.o.lines = 120, 40

local function flush() vim.wait(20, function() return false end, 5) end

local function recorder()
   local calls = {}
   return calls, function(item, index) calls[#calls + 1] = { item = item, index = index } end
end

-- The window that draws the border and title around the dialog's text.
local function border_lines(title)
   for _, winid in ipairs(vim.api.nvim_list_wins()) do
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(winid), 0, -1, false)
      if lines[1] and lines[1]:find("■ " .. title .. " ■", 1, true) then return lines end
   end
end

local function focused_highlight(bufnr)
   for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
      if mark[4].hl_group == "ZenvoyButtonActive" then return mark end
   end
end

t.test("a confirmation is a small centered dialog with square corners and the safe choice focused", function()
   local calls, callback = recorder()
   dialog.select({ "Cancel", "Send" }, { prompt = "Send this email?", title = "Send email" }, callback)
   local shown = assert(t.dialog(), "the dialog should open")
   t.equal(shown.winid, vim.api.nvim_get_current_win())
   t.equal({ "Send this email?", "", "[ Cancel ]   [ Send ]" }, vim.tbl_map(vim.trim, shown.lines))
   t.equal({ "Cancel", "Send" }, shown.labels)
   t.equal("Cancel", shown.focus)
   t.equal(false, vim.bo[shown.bufnr].modifiable)

   local frame = assert(border_lines("Send email"), "the title should be on the border")
   t.equal("┌", frame[1]:sub(1, 3))
   t.equal("└", frame[#frame]:sub(1, 3))
   local row, col = unpack(vim.api.nvim_win_get_position(shown.winid))
   local width, height = vim.api.nvim_win_get_width(shown.winid), vim.api.nvim_win_get_height(shown.winid)
   local geometry = vim.inspect({ row = row, col = col, width = width, height = height })
   assert(math.abs(col + width / 2 - vim.o.columns / 2) <= 3, geometry)
   assert(math.abs(row + height / 2 - vim.o.lines / 2) <= 3, geometry)
   assert(width <= 64 and height == 3, geometry)

   local mark = assert(focused_highlight(shown.bufnr))
   t.equal("[ Cancel ]", shown.lines[3]:sub(mark[3] + 1, mark[4].end_col))
   shown.press("<Esc>")
   t.equal({ {} }, calls)
end)

t.test("h, l, arrows and Tab move between buttons and Enter returns the item and index", function()
   local previous = vim.api.nvim_get_current_win()
   local calls, callback = recorder()
   dialog.select({ "Cancel", "Send" }, { prompt = "Send?" }, callback)
   local function press(lhs)
      t.dialog().press(lhs)
      return t.dialog().focus
   end
   t.equal("Send", press("l"))
   t.equal("Cancel", press("l"))
   t.equal("Send", press("<Left>"))
   t.equal("Cancel", press("<Right>"))
   t.equal("Send", press("<Tab>"))
   t.equal("Cancel", press("<S-Tab>"))
   t.equal("Send", press("h"))
   local shown = t.dialog()
   local mark = assert(focused_highlight(shown.bufnr))
   t.equal("[ Send ]", shown.lines[#shown.lines]:sub(mark[3] + 1, mark[4].end_col))
   -- Other motions cannot move the cursor away from the focused button.
   vim.api.nvim_win_set_cursor(shown.winid, { 1, 0 })
   vim.api.nvim_exec_autocmds("CursorMoved", { buffer = shown.bufnr })
   t.equal("Send", t.dialog().focus)
   shown.press("<CR>")
   t.equal({ { item = "Send", index = 2 } }, calls)
   t.equal(nil, t.dialog())
   t.equal(previous, vim.api.nvim_get_current_win())
end)

t.test("Escape, q, Ctrl-c and leaving or closing the window cancel exactly once", function()
   local previous = vim.api.nvim_get_current_win()
   for _, lhs in ipairs({ "<Esc>", "q", "<C-C>" }) do
      local calls, callback = recorder()
      dialog.select({ "Keep editing", "Discard" }, { prompt = "Discard this email?" }, callback)
      t.dialog().press(lhs)
      flush()
      t.equal({ {} }, calls)
      t.equal(previous, vim.api.nvim_get_current_win())
   end

   local calls, callback = recorder()
   dialog.select({ "Keep editing", "Discard" }, {}, callback)
   vim.api.nvim_set_current_win(previous)
   flush()
   t.equal({ {} }, calls)
   t.equal(nil, t.dialog())

   calls, callback = recorder()
   dialog.select({ "Keep editing", "Discard" }, {}, callback)
   vim.api.nvim_win_close(t.dialog().winid, true)
   flush()
   t.equal({ {} }, calls)
   t.equal(nil, t.dialog())
end)

t.test("long links wrap inside the dialog instead of being cut", function()
   local url = "https://example.com/" .. string.rep("a", 150) .. "?id=1"
   dialog.select({ "Open link", "Copy link", "Cancel" }, { prompt = "Link: " .. url, title = "Link" }, function() end)
   local shown = t.dialog()
   t.equal({ "Open link", "Copy link", "Cancel" }, shown.labels)
   local text = ""
   for index = 1, #shown.lines - 2 do
      assert(vim.api.nvim_strwidth(shown.lines[index]) <= 64, shown.lines[index])
      text = text .. shown.lines[index]
   end
   assert(text:find(url, 1, true), shown.text)
   shown.press("q")
end)

t.test("very long prompts are shortened so the choices stay visible", function()
   dialog.select({ "Cancel", "Open anyway" }, { prompt = string.rep("word ", 2000) }, function() end)
   local shown = t.dialog()
   t.equal({ "Cancel", "Open anyway" }, shown.labels)
   assert(#shown.lines <= vim.o.lines, #shown.lines)
   assert(shown.lines[#shown.lines - 2]:find("…$"), shown.lines[#shown.lines - 2])
   t.equal(#shown.lines, vim.api.nvim_win_get_height(shown.winid))
   shown.press("q")
end)

t.test("control and direction characters from email do not reach the dialog", function()
   dialog.select({ "Cancel", "Open\27[31m anyway" }, {
      prompt = "invoice\226\128\174fdp.exe\27[2J can run code", title = "Open\nattachment",
   }, function() end)
   local shown = t.dialog()
   t.equal("invoicefdp.exe[2J can run code", vim.trim(shown.lines[1]))
   t.equal({ "Cancel", "Open[31m anyway" }, shown.labels)
   assert(border_lines("Open attachment"), "the title should be a single line")
   shown.press("q")
end)

t.test("lists move with j and k, keep both ends of long names and return the index", function()
   local long = string.rep("x", 100) .. ".pdf.exe"
   local calls, callback = recorder()
   dialog.select({ "report.pdf", long, "All attachments" }, {
      prompt = "Which attachment do you want to save?", title = "Save attachment", kind = "list",
   }, callback)
   local shown = t.dialog()
   t.equal("report.pdf", shown.focus)
   t.equal("  All attachments", shown.lines[#shown.lines])
   local row = shown.lines[#shown.lines - 1]
   assert(row:find("…", 1, true) and row:find("%.pdf%.exe$") and vim.api.nvim_strwidth(row) <= 64, row)
   shown.press("j")
   assert(t.dialog().focus:find("…", 1, true))
   shown.press("k")
   shown.press("<Up>")
   t.equal("All attachments", t.dialog().focus)
   shown.press("<CR>")
   t.equal({ { item = "All attachments", index = 3 } }, calls)
end)

t.test("too many buttons become a list, and format_item labels the items", function()
   local items = { { name = "a" }, { name = "b" }, { name = "c" }, { name = "d" }, { name = "e" } }
   local calls, callback = recorder()
   dialog.select(items, { format_item = function(item) return item.name:upper() end }, callback)
   local shown = t.dialog()
   t.equal({ "› A", "  B", "  C", "  D", "  E" }, shown.lines)
   shown.press("<Down>")
   shown.press("<CR>")
   t.equal(items[2], calls[1].item)
   t.equal(2, calls[1].index)
end)

t.test("a choice can open the next dialog, and a new dialog cancels an open one", function()
   local previous = vim.api.nvim_get_current_win()
   local second, callback = recorder()
   dialog.select({ "Open", "Cancel" }, { prompt = "file.sh" }, function(choice)
      if choice == "Open" then
         dialog.select({ "Cancel", "Open anyway" }, { prompt = "file.sh can run code" }, callback)
      end
   end)
   t.answer("Open")
   flush()
   local shown = assert(t.dialog(), "the second dialog should stay open")
   t.equal({ "Cancel", "Open anyway" }, shown.labels)
   t.equal(shown.winid, vim.api.nvim_get_current_win())
   t.answer("Open anyway")
   t.equal({ { item = "Open anyway", index = 2 } }, second)
   t.equal(previous, vim.api.nvim_get_current_win())

   local first
   first, callback = recorder()
   dialog.select({ "Cancel", "Send" }, {}, callback)
   dialog.select({ "Cancel", "Discard" }, {}, function() end)
   t.equal({ {} }, first)
   t.equal({ "Cancel", "Discard" }, t.dialog().labels)
   dialog.close()
   t.equal(nil, t.dialog())
end)

t.test("an empty list cancels at once", function()
   local calls, callback = recorder()
   dialog.select({}, { prompt = "Nothing" }, callback)
   t.equal({ {} }, calls)
   t.equal(nil, t.dialog())
end)

t.finish("dialog_spec")

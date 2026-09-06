vim.opt.runtimepath:prepend(vim.fn.getcwd())

local failures = {}
local tests_run = 0

local function assert_equal(expected, actual, message)
   if expected ~= actual then
      error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
   end
end

local function test(name, callback)
   tests_run = tests_run + 1
   local ok, err = pcall(callback)

   if not ok then
      table.insert(failures, string.format("%s: %s", name, err))
   end
end

local function find_mapping(bufnr, lhs)
   for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if mapping.lhs == lhs then
         return mapping
      end
   end
end

local function reload_ui()
   for _, module in ipairs({
      "zenvoy.config",
      "zenvoy.keymaps",
      "zenvoy.state",
      "zenvoy.ui",
      "zenvoy.ui.layout",
      "zenvoy.ui.sidebar",
      "zenvoy.ui.envelope",
      "zenvoy.utils.date",
   }) do
      package.loaded[module] = nil
   end

   local config = require("zenvoy.config")
   config.setup()

   return require("zenvoy.ui"), require("zenvoy.state"), config
end

test("applies the configured keys to Zenvoy buffers", function()
   local ui, state = reload_ui()

   ui.create()

   assert_equal(true, state.is_open, "open state")
   assert_equal(false, state.email_visible, "initial email visibility")
   assert_equal(state.listing_popup.bufnr, vim.api.nvim_get_current_buf(), "initial focused buffer")

   for _, lhs in ipairs({ "q", "<CR>" }) do
      assert(find_mapping(state.listing_popup.bufnr, lhs), string.format("missing %s listing mapping", lhs))
      assert(find_mapping(state.email_popup.bufnr, lhs), string.format("missing %s email mapping", lhs))
   end

   ui.close()
   assert_equal(false, state.is_open, "closed state")
end)

test("renders mailbox hierarchy stored before the layout is created", function()
   local ui, state = reload_ui()

   ui.set_mailboxes({
      { id = "Inbox", name = "Inbox" },
      { id = "[Gmail]/Spam", name = "Spam" },
   })
   ui.create()

   local lines = vim.api.nvim_buf_get_lines(state.sidebar_popup.bufnr, 0, -1, false)
   assert(vim.deep_equal(lines, { "Inbox", "  Spam" }), vim.inspect(lines))

   ui.close()
end)

test("renders envelope rows stored before the layout is created", function()
   local ui, state = reload_ui()

   ui.set_envelopes({
      {
         id = "30222",
         subject = "First email",
         from = { { name = "Alice" } },
         flags = {},
      },
      {
         id = "30221",
         subject = "Second email",
         from = { { email = "bob@example.com" } },
         flags = { { iana = "seen", raw = "\\Seen" } },
      },
   })
   ui.create()

   local lines = vim.api.nvim_buf_get_lines(state.listing_popup.bufnr, 0, -1, false)
   local border = table.concat(vim.api.nvim_buf_get_lines(state.listing_popup.border.bufnr, 0, -1, false))
   assert_equal(2, #lines, "rendered envelope count")
   assert(border:find("Emails (2)", 1, true), border)
   assert(lines[1]:find("■", 1, true), lines[1])
   assert(lines[1]:find("Alice", 1, true), lines[1])
   assert(lines[1]:find("First email", 1, true), lines[1])
   assert(lines[2]:find("bob@example.com", 1, true), lines[2])
   assert(lines[2]:find("Second email", 1, true), lines[2])

   ui.close()
end)

test("uses enter to open an email and q to go back before closing", function()
   local ui, state = reload_ui()
   local windows_before = #vim.api.nvim_list_wins()

   ui.create()

   find_mapping(state.listing_popup.bufnr, "<CR>").callback()
   assert_equal(true, state.email_visible, "visible email state")
   assert_equal(state.email_popup.bufnr, vim.api.nvim_get_current_buf(), "focused email buffer")

   find_mapping(state.email_popup.bufnr, "q").callback()
   assert_equal(false, state.email_visible, "hidden email state")
   assert_equal(true, state.is_open, "layout remains open after going back")
   assert_equal(state.listing_popup.bufnr, vim.api.nvim_get_current_buf(), "focused listing buffer")

   find_mapping(state.listing_popup.bufnr, "q").callback()
   assert_equal(false, state.is_open, "layout closes from listing")
   assert_equal(windows_before, #vim.api.nvim_list_wins(), "window cleanup")
end)

test("honors a custom mapping and disabled default", function()
   local ui, state, config = reload_ui()

   config.setup({
      keymaps = {
         ["q"] = false,
         ["x"] = "close_or_back",
      },
   })

   ui.create()

   assert_equal(nil, find_mapping(state.listing_popup.bufnr, "q"), "disabled q mapping")
   assert(find_mapping(state.listing_popup.bufnr, "x"), "missing custom x mapping")

   ui.close()
end)

if #failures > 0 then
   error(table.concat(failures, "\n"))
end

print(string.format("ui_keymaps_spec: %d tests passed", tests_run))

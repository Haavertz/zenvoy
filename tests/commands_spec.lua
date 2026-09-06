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

local function create_context()
   local layout = {
      updates = {},
      unmount_count = 0,
   }

   function layout:update(box)
      table.insert(self.updates, box)
   end

   function layout:unmount()
      self.unmount_count = self.unmount_count + 1
   end

   local state = {
      is_open = true,
      email_visible = false,
      layout = layout,
      sidebar_popup = { bufnr = 1 },
      listing_popup = { bufnr = 2 },
      email_popup = { bufnr = 3 },
   }

   local observed = {
      current_buffer = state.listing_popup.bufnr,
      focused_popup = nil,
      notifications = {},
   }

   local context = {
      state = state,
      create_box = function()
         return state.email_visible and "email-box" or "listing-box"
      end,
      focus = function(popup)
         observed.focused_popup = popup
      end,
      current_buffer = function()
         return observed.current_buffer
      end,
      notify = function(message)
         table.insert(observed.notifications, message)
      end,
   }

   return context, state, layout, observed
end

local function load_commands(context)
   for _, module in ipairs({
      "zenvoy.commands",
      "zenvoy.commands.email",
      "zenvoy.commands.session",
   }) do
      package.loaded[module] = nil
   end

   return require("zenvoy.commands").create(context)
end

test("shows and hides the email pane", function()
   local context, state, layout, observed = create_context()
   local commands = load_commands(context)

   commands.show_email()

   assert_equal(true, state.email_visible, "email visible after show")
   assert_equal("email-box", layout.updates[1], "expanded layout")
   assert_equal(state.email_popup, observed.focused_popup, "focused email popup")

   commands.hide_email()

   assert_equal(false, state.email_visible, "email hidden after hide")
   assert_equal("listing-box", layout.updates[2], "listing layout")
   assert_equal(state.listing_popup, observed.focused_popup, "focused listing popup")
end)

test("goes back from email before closing the session", function()
   local context, state, layout = create_context()
   local commands = load_commands(context)

   commands.show_email()
   commands.close_or_back()

   assert_equal(true, state.is_open, "session remains open after back")
   assert_equal(false, state.email_visible, "email hidden after back")
   assert_equal(0, layout.unmount_count, "layout remains mounted after back")

   commands.close_or_back()

   assert_equal(false, state.is_open, "closed session")
   assert_equal(1, layout.unmount_count, "unmounted layout")
   assert_equal(nil, state.layout, "cleared layout state")
   assert_equal(nil, state.sidebar_popup, "cleared sidebar popup")
   assert_equal(nil, state.listing_popup, "cleared listing popup")
   assert_equal(nil, state.email_popup, "cleared email popup")
end)

test("uses enter according to the focused buffer", function()
   local context, state, layout, observed = create_context()
   local commands = load_commands(context)

   observed.current_buffer = state.sidebar_popup.bufnr
   commands.enter()
   assert_equal(state.listing_popup, observed.focused_popup, "sidebar enters listing")

   observed.current_buffer = state.listing_popup.bufnr
   commands.enter()
   assert_equal(true, state.email_visible, "listing opens email")
   assert_equal("email-box", layout.updates[1], "email layout after enter")
end)

test("does not expose disabled email command placeholders", function()
   local context = create_context()
   local commands = load_commands(context)

   assert_equal(nil, commands.compose, "compose command")
   assert_equal(nil, commands.reply, "reply command")
end)

if #failures > 0 then
   error(table.concat(failures, "\n"))
end

print(string.format("commands_spec: %d tests passed", tests_run))

local M = {}

local state = require("zenvoy.state")
local layout = require("zenvoy.ui.layout")
local keymap = require("zenvoy.keymaps")
local config = require("zenvoy.config")
local command_factory = require("zenvoy.commands")
local sidebar = require("zenvoy.ui.sidebar")
local envelope = require("zenvoy.ui.envelope")
local message = require("zenvoy.ui.message")
local activity = require("zenvoy.ui.activity").new()
local Mailboxes = require("zenvoy.ui.mailboxes")
local pending_request
local pending_message
local message_reader
local mailbox_loader
local composer
local pending_layout_update

local Layout = require("nui.layout")

local function focus(popup)
   if popup and popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
      vim.api.nvim_set_current_win(popup.winid)
   end
end

local function create_box()
   local sidebar_width = config.get().sidebar.width

   if state.email_visible then
      return Layout.Box({
         Layout.Box(state.sidebar_popup, { size = sidebar_width }),
         Layout.Box({
            Layout.Box(state.listing_popup, { size = "50%", position = { row = 1, col = 3 }}),
            Layout.Box(state.email_popup, { grow = 1 }),
         }, { dir = "col", grow = 1 }),
      }, { dir = "row" })
   end

   return Layout.Box({
      Layout.Box(state.sidebar_popup, { size = sidebar_width }),
      Layout.Box(state.listing_popup, { grow = 1 }),
   }, { dir = "row" })
end

local function update_layout()
   local main = state.layout
   if not main then return end
   if state.email_visible then
      pending_layout_update = nil
      main:update(create_box())
      return
   end
   -- NUI schedules positioning against the windows present during update().
   -- Let that work drain before removing a newly opened message's border.
   if pending_layout_update and pending_layout_update.layout == main then return end
   local pending = { layout = main }
   pending_layout_update = pending
   vim.schedule(function()
      if pending_layout_update ~= pending then return end
      pending_layout_update = nil
      if state.layout ~= main or not state.is_open or state.email_visible then return end
      main:update(create_box())
   end)
end

local function cancel_message()
   local pending = pending_message
   pending_message = nil
   state.open_envelope = nil
   if pending then
      pending.finish()
      if pending.request then pending.request:cancel() end
   end
end

local function open_message(selected)
   cancel_message()
   state.open_envelope = selected
   local popup = state.email_popup
   local mailbox = state.current_folder
   message.render(popup, selected, "")
   local pending = { finish = activity:start("Loading email") }
   pending_message = pending
   local function receive(err, result)
      if pending_message ~= pending then return end
      pending_message = nil
      if not pending.finish() or state.email_popup ~= popup or not state.email_visible then return end
      if err then
         message.render(popup, selected, "Unable to load email.\n" .. err)
         vim.notify("Zenvoy: " .. err, vim.log.levels.ERROR)
      else
         message.render(popup, result)
         selected.flags = selected.flags or {}
         local seen = false
         for _, flag in ipairs(selected.flags) do
            local value = type(flag) == "table" and (flag.iana or flag.raw) or flag
            if type(value) == "string" and value:lower():gsub("^\\", "") == "seen" then seen = true end
         end
         if not seen then selected.flags[#selected.flags + 1] = "seen" end
         M.set_envelopes(state.envelopes)
      end
   end
   if not message_reader then
      receive("Message reader is not configured")
      return
   end
   local ok, request = pcall(message_reader, selected.id, receive, mailbox)
   if ok then pending.request = request else receive(tostring(request)) end
end

local mailboxes = Mailboxes.new({
   load = function(mailbox, callback) return mailbox_loader(mailbox, callback) end,
   activity = function(label) return activity:start(label) end,
   on_select = function(mailbox)
      cancel_message()
      if pending_request then pending_request:cancel(); pending_request = nil end
      state.current_folder, state.current_page = mailbox, 1
      if state.email_visible then
         state.email_visible = false
         update_layout()
      end
      M.set_envelopes({})
   end,
   on_result = function(records) M.set_envelopes(records) end,
   on_error = function(err) vim.notify("Zenvoy: " .. err, vim.log.levels.ERROR) end,
})

local function select_mailbox(options)
   local popup = state.sidebar_popup
   if not mailbox_loader or not state.is_open or not popup or not vim.api.nvim_win_is_valid(popup.winid) then return end
   local selected = state.mailboxes[vim.api.nvim_win_get_cursor(popup.winid)[1]]
   if selected then mailboxes:select(selected.id, options) end
end

local function clear_session()
   pending_layout_update = nil
   cancel_message()
   mailboxes:clear()
   if composer then composer:detach(); composer = nil end
   message_reader = nil
   mailbox_loader = nil
   activity:clear()
   if pending_request then
      pending_request:cancel()
      pending_request = nil
   end
end

local commands = command_factory.create({
   state = state,
   create_box = create_box,
   update_layout = update_layout,
   focus = focus,
   current_buffer = vim.api.nvim_get_current_buf,
   notify = vim.notify,
   on_close = clear_session,
   request_close = function(done)
      if composer then composer:request_close(done) else done() end
   end,
   on_compose = function(options)
      if composer then composer:open(options) end
   end,
   on_select_mailbox = select_mailbox,
   selected_envelope = function()
      if state.email_popup and vim.api.nvim_get_current_buf() == state.email_popup.bufnr then
         return state.open_envelope
      end
      local popup = state.listing_popup
      if not popup or not popup.winid or not vim.api.nvim_win_is_valid(popup.winid) then return end
      return state.envelopes[vim.api.nvim_win_get_cursor(popup.winid)[1]]
   end,
   on_open_email = open_message,
   on_hide_email = cancel_message,
})

local function apply_keymaps(popup)
   keymap.apply(popup.bufnr, config.get().keymaps, commands)
end

function M.close(force)
   commands.close(force)
end

---Inject the backend operation from the composition root.
---@param reader fun(id: string, callback: fun(err: string?, message: ZenvoyMessage?), mailbox?: string): ZenvoyRequest?
function M.set_message_reader(reader)
   cancel_message()
   message_reader = reader
end

function M.set_mailbox_loader(loader)
   mailboxes:clear()
   mailbox_loader = loader
end

function M.set_composer(operations)
   if composer then composer:detach() end
   composer = require("zenvoy.ui.composer").new({
      prepare_reply = operations.prepare_reply,
      send = operations.send,
      activity = function(label) return activity:start(label) end,
      notify = vim.notify,
   })
end

---@param request ZenvoyRequest
function M.track_request(request)
   if pending_request then pending_request:cancel() end
   pending_request = request
end

---@param messages string|string[]
---@return fun(): boolean
function M.start_activity(messages)
   return activity:start(messages)
end

function M.set_mailboxes(mailboxes)
   state.mailboxes = mailboxes or {}

   if state.sidebar_popup then
      sidebar.render(state.sidebar_popup.bufnr, state.mailboxes)
   end
end

function M.set_envelopes(envelopes)
   state.envelopes = envelopes or {}

   if state.listing_popup then
      local popup = state.listing_popup
      local cursor = popup.winid and vim.api.nvim_win_is_valid(popup.winid) and vim.api.nvim_win_get_cursor(popup.winid)
      state.listing_popup.border:set_text("top", (" ■ Emails (%d) ■ "):format(#state.envelopes), "center")
      envelope.render(state.listing_popup.bufnr, state.envelopes)
      if cursor then
         cursor[1] = math.max(1, math.min(cursor[1], #state.envelopes))
         vim.api.nvim_win_set_cursor(popup.winid, cursor)
      end
   end
end

function M.create()
   if state.is_open then
      focus(state.listing_popup)
      return state.layout
   end

   state.sidebar_popup = layout.create_popup("Folders")
   state.listing_popup = layout.create_popup("Emails")
   state.email_popup = layout.create_popup("", { wrap = true, linebreak = true, cursorline = false })
   state.email_visible = false

   local main = Layout(
      {
         position = "50%",
         relative = "editor",
         size = {
            width = "90%",
            height = "80%",
         },
      },
      create_box()
   )

   state.layout = main
   main:mount()
   state.is_open = true
   activity:attach(state.sidebar_popup)
   vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(state.sidebar_popup.winid),
      once = true,
      callback = function()
         if state.layout == main then M.close(true) end
      end,
   })

   vim.bo[state.sidebar_popup.bufnr].filetype = "zenvoy-folder-listing"
   vim.bo[state.listing_popup.bufnr].filetype = "zenvoy-envelope-listing"
   vim.bo[state.email_popup.bufnr].filetype = "zenvoy-email"

   sidebar.render(state.sidebar_popup.bufnr, state.mailboxes)
   M.set_envelopes(state.envelopes)

   apply_keymaps(state.sidebar_popup)
   apply_keymaps(state.listing_popup)
   apply_keymaps(state.email_popup)

   vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = state.sidebar_popup.bufnr,
      callback = function()
         if state.layout == main and vim.api.nvim_get_current_buf() == state.sidebar_popup.bufnr then
            select_mailbox()
         end
      end,
   })

   -- Let the native press focus the clicked window, then open on release.
   -- Explicit user mappings (including false) keep control of this key.
   if config.get().keymaps["<LeftRelease>"] == nil then
      vim.keymap.set("n", "<LeftRelease>", function()
         local mouse = vim.fn.getmousepos()
         local popup = state.listing_popup
         if not popup or mouse.winid ~= popup.winid or mouse.column < 1 or not state.envelopes[mouse.line] then return end
         vim.api.nvim_win_set_cursor(popup.winid, { mouse.line, 0 })
         commands.show_email()
      end, { buffer = state.listing_popup.bufnr, desc = "Zenvoy: open clicked email", silent = true })
   end

   focus(state.listing_popup)

   return main
end

return M

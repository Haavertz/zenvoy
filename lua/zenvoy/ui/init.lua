local M = {}

local state = require("zenvoy.state")
local layout = require("zenvoy.ui.layout")
local keymap = require("zenvoy.keymaps")
local config = require("zenvoy.config")
local command_factory = require("zenvoy.commands")
local sidebar = require("zenvoy.ui.sidebar")
local envelope = require("zenvoy.ui.envelope")
local message = require("zenvoy.ui.message")
local highlights = require("zenvoy.ui.highlights")
local activity = require("zenvoy.ui.activity").new()
local Mailboxes = require("zenvoy.ui.mailboxes")
local Process = require("zenvoy.core.process")
local ImageCache = require("zenvoy.core.image_cache")
local ImageController = require("zenvoy.ui.images")
local image_preview = require("zenvoy.ui.image_preview")
local Reader = require("zenvoy.ui.reader")
local dialog = require("zenvoy.ui.dialog")
local help = require("zenvoy.ui.help")
local mailboxes
local pending_request
local pending_message
local message_reader
local mailbox_loader
local attachment_downloader
local composer
local image_cache
local image_controller
local reader
-- The message shown in the email pane:
-- { envelope, mailbox, mode, message?, error?, view?, width? }.
local current

-- Panes on screen: "list" (folders and emails), "split" (the opened email below the
-- list) or "full" (the email over the whole window).
local shape
-- Set until NUI's scheduled positioning after the last layout change has run. NUI
-- fails if a window it positions closes first, so changes that close windows wait.
local settling
local deferred
-- Windows closed during a layout change are hidden panes, not closed by the user.
local switching = false
local windows = {}
local listing_cursor
local WINDOWS_GROUP = "ZenvoyWindows"

local Layout = require("nui.layout")

local function focus(popup)
   if popup and popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
      vim.api.nvim_set_current_win(popup.winid)
   end
end

local function wanted_shape()
   if not state.email_visible then return "list" end
   return state.email_fullscreen and "full" or "split"
end

local function create_box(box_shape)
   box_shape = box_shape or wanted_shape()
   local sidebar_width = config.get().sidebar.width

   if box_shape == "full" then
      return Layout.Box({ Layout.Box(state.email_popup, { grow = 1 }) }, { dir = "row" })
   end

   if box_shape == "split" then
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

local function email_cursor()
   local popup = state.email_popup
   if not state.email_visible or not popup or not popup.winid or not vim.api.nvim_win_is_valid(popup.winid) then
      return nil
   end
   return vim.api.nvim_win_get_cursor(popup.winid)
end

local function item_under_cursor()
   local cursor = email_cursor()
   if not cursor or not current or not current.view then return nil end
   return message.item_at(current.view, cursor[1], cursor[2])
end

-- The message's bottom border also shows activity while the email covers the window;
-- the activity takes precedence there.
local function show_status(item)
   local popup = state.email_popup
   if popup and not activity:showing(popup) then message.status(popup, item) end
end

local function render_options(mode)
   local options = config.get().reader
   return { mode = mode, max_width = options.max_width, fold_quotes = options.fold_quotes }
end

---Render the current message: loaded, still loading (headers only) or failed.
---@param keep_position? boolean Keep the cursor at about the same place in the text.
local function render_current(keep_position)
   local popup = state.email_popup
   if not current or not popup then return end
   local winid = popup.winid
   local shown = winid ~= nil and vim.api.nvim_win_is_valid(winid)
   local before
   if keep_position and shown then
      before = { row = vim.api.nvim_win_get_cursor(winid)[1], count = vim.api.nvim_buf_line_count(popup.bufnr) }
   end
   if current.message then
      current.view = message.render(popup, current.message, nil, render_options(current.mode))
   else
      current.view = message.render(popup, current.envelope, current.error or "", render_options(current.mode))
   end
   current.width = shown and vim.api.nvim_win_get_width(winid) or nil
   if before and before.row > 1 then
      local count = vim.api.nvim_buf_line_count(popup.bufnr)
      local row = math.floor((before.row - 1) * count / before.count + 0.5) + 1
      vim.api.nvim_win_set_cursor(winid, { math.max(1, math.min(count, row)), 0 })
   end
   show_status(nil)
end

-- Text is wrapped to the pane, so a pane that changed width is rendered again.
local function refit_message()
   local popup = state.email_popup
   if not current or not state.email_visible or not popup or not popup.winid then return end
   if not vim.api.nvim_win_is_valid(popup.winid) or current.width == vim.api.nvim_win_get_width(popup.winid) then
      return
   end
   -- Rendered images belong to the old lines.
   if image_controller then image_controller:clear() end
   render_current(true)
end

local function attach_activity()
   if shape == "full" then
      activity:attach(state.email_popup, function() show_status(item_under_cursor()) end)
   elseif state.sidebar_popup then
      activity:attach(state.sidebar_popup)
   end
end

local function track_windows(main)
   windows = {}
   if main.winid then windows[main.winid] = true end
   for _, popup in ipairs({ state.sidebar_popup, state.listing_popup, state.email_popup }) do
      if popup and popup.winid then windows[popup.winid] = true end
   end
end

local function settle()
   local token = {}
   settling = token
   -- Queued after NUI's own callback, so this runs once the windows are positioned.
   vim.schedule(function()
      if settling == token then settling = nil end
   end)
end

local function apply_layout(main, next_shape)
   local listing = state.listing_popup
   local listed = listing.winid ~= nil and vim.api.nvim_win_is_valid(listing.winid)
   if listed then listing_cursor = vim.api.nvim_win_get_cursor(listing.winid) end
   activity:detach()
   switching = true
   local ok, err = pcall(main.update, main, create_box(next_shape))
   switching = false
   shape = next_shape
   settle()
   track_windows(main)
   -- The list comes back where it was, on the email that was open.
   if not listed and listing.winid and listing_cursor then
      local row = math.min(listing_cursor[1], vim.api.nvim_buf_line_count(listing.bufnr))
      pcall(vim.api.nvim_win_set_cursor, listing.winid, { math.max(1, row), listing_cursor[2] })
   end
   attach_activity()
   refit_message()
   if not ok then error(err, 0) end
end

local function update_layout()
   local main = state.layout
   if not main then return end
   local next_shape = wanted_shape()
   if next_shape == shape then return end
   -- Only changes to "split" keep every pane that is on screen.
   if next_shape ~= "split" and settling then
      -- Show the new panes now, so they can take focus, and close the others once NUI
      -- has positioned the windows of the previous change.
      if shape ~= "split" then apply_layout(main, "split") end
      if not deferred then
         local request = {}
         deferred = request
         vim.schedule(function()
            if deferred ~= request then return end
            deferred = nil
            if state.layout == main and state.is_open then update_layout() end
         end)
      end
      return
   end
   apply_layout(main, next_shape)
end

local function cancel_message()
   local pending = pending_message
   pending_message = nil
   state.open_envelope = nil
   current = nil
   if image_controller then image_controller:clear() end
   show_status(nil)
   if pending then
      pending.finish()
      if pending.request then pending.request:cancel() end
   end
end

local function open_message(selected)
   -- Opening an email keeps the list on its page.
   mailboxes:cancel_page()
   cancel_message()
   state.open_envelope = selected
   local popup = state.email_popup
   local mailbox = state.current_folder
   local opened = { envelope = selected, mailbox = mailbox, mode = config.get().reader.prefer }
   current = opened
   render_current()
   local pending = { finish = activity:start("Loading email") }
   pending_message = pending
   local function receive(err, result)
      if pending_message ~= pending then return end
      pending_message = nil
      if not pending.finish() or state.email_popup ~= popup or not state.email_visible then return end
      if err then
         if current == opened then
            opened.error = "Unable to load email.\n" .. err
            render_current()
         end
         vim.notify("Zenvoy: " .. err, vim.log.levels.ERROR)
      else
         if current == opened then
            opened.message = result
            render_current()
         end
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

local function show_image(item)
   local popup = state.email_popup
   local cursor = email_cursor()
   if not cursor then return end
   if not item then
      item = item_under_cursor()
      if not item or item.kind ~= "image" then
         -- Fall back to an image anywhere on the cursor row.
         item = nil
         for _, candidate in ipairs(current and current.view and current.view.items or {}) do
            if candidate.kind == "image" and candidate.row == cursor[1] - 1 then
               item = candidate
               break
            end
         end
      end
   end
   local image = item and item.image
   if not image then
      if item and item.kind == "image" then
         vim.notify("Zenvoy: this image has no source that can be displayed", vim.log.levels.INFO)
      end
      return
   end
   local row = item.row + 1

   if not image_controller then
      image_cache = ImageCache.new(Process.new({ timeout = config.get().himalaya.timeout }))
      image_controller = ImageController.new({
         preview = image_preview,
         choose = function(items, options, callback) dialog.select(items, options, callback) end,
         load = function(source, callback) return image_cache:load(source, callback) end,
         activity = function(label) return activity:start(label) end,
         notify = vim.notify,
      })
   end
   local target = vim.tbl_extend("force", {}, image, {
      buffer = popup.bufnr,
      window = popup.winid,
      row = row,
   })
   image_controller:activate(target)
end

local function get_reader()
   if not reader then
      reader = Reader.new({
         choose = function(items, options, callback) dialog.select(items, options, callback) end,
         input = function(options, callback) vim.ui.input(options, callback) end,
         open = function(target) return vim.ui.open(target) end,
         download = function(id, mailbox, ids, directory, callback)
            if not attachment_downloader then
               callback("Attachment downloads are not configured")
               return
            end
            return attachment_downloader(id, mailbox, ids, directory, callback)
         end,
         activity = function(label) return activity:start(label) end,
         notify = vim.notify,
         download_dir = function() return config.get().attachments.download_dir end,
      })
   end
   return reader
end

local function listed_attachments()
   local list = {}
   for _, attachment in ipairs(current and current.message and current.message.attachments or {}) do
      if not attachment.referenced then list[#list + 1] = attachment end
   end
   return list
end

local function move_to(item)
   local popup = state.email_popup
   if not item or not popup or not popup.winid or not vim.api.nvim_win_is_valid(popup.winid) then return end
   vim.api.nvim_win_set_cursor(popup.winid, { item.row + 1, item.col })
   -- Reveal targets inside collapsed quotations.
   vim.api.nvim_win_call(popup.winid, function() vim.cmd("silent! normal! zv") end)
   show_status(item)
end

-- Long quoted replies are folded. Enter on a collapsed one opens it, and Enter on
-- quoted text that is not a link or an image collapses it again.
local function toggle_quote(collapsed_only)
   local winid = state.email_popup.winid
   return vim.api.nvim_win_call(winid, function()
      local row = vim.api.nvim_win_get_cursor(winid)[1]
      if vim.fn.foldlevel(row) == 0 or (collapsed_only and vim.fn.foldclosed(row) == -1) then return false end
      vim.cmd("silent! normal! za")
      return true
   end)
end

local function reader_action(action)
   if not current or not state.email_visible or not state.email_popup
      or vim.api.nvim_get_current_buf() ~= state.email_popup.bufnr then
      return
   end
   local context = { id = current.envelope.id, mailbox = current.mailbox }
   local item = item_under_cursor()
   if action == "activate" then
      if toggle_quote(item ~= nil) or not item then return end
      if item.kind == "image" then
         if item.url then
            dialog.select({ "Show image", "Open link", "Copy link", "Cancel" }, {
               prompt = "Image linking to " .. item.url:gsub("%c", ""), title = "Image link",
            }, function(choice)
               if choice == "Show image" then
                  show_image(item)
               elseif choice == "Open link" then
                  get_reader():open_link(item.url)
               elseif choice == "Copy link" then
                  get_reader():copy_link(item.url)
               end
            end)
         else
            show_image(item)
         end
      elseif item.kind == "link" then
         get_reader():link_menu(item.url)
      elseif item.kind == "attachment" and current.message then
         get_reader():attachment_menu(item.attachment, context)
      end
   elseif action == "open_link" then
      if item and item.url then get_reader():open_link(item.url) end
   elseif action == "save_attachment" then
      if not current.message then return end
      if item and item.kind == "attachment" then
         get_reader():save(item.attachment, context)
      else
         get_reader():save_any(listed_attachments(), context)
      end
   elseif action == "toggle_view" then
      if not current.message then return end
      if not current.message.has_html then
         vim.notify("Zenvoy: this email has no HTML version", vim.log.levels.INFO)
         return
      end
      current.mode = current.view and current.view.mode == "html" and "plain" or "html"
      render_current()
   elseif action == "next_item" or action == "previous_item" then
      local cursor = email_cursor()
      if not cursor or not current.view then return end
      move_to(message.adjacent_item(current.view, cursor[1], cursor[2], action == "previous_item"))
   end
end

-- A new page replaces the list and starts at its first email; an open email stays.
local function show_page(page, records)
   state.current_page = page
   M.set_envelopes(records)
   listing_cursor = { 1, 0 }
   local popup = state.listing_popup
   if popup and popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
      vim.api.nvim_win_set_cursor(popup.winid, { 1, 0 })
   end
end

mailboxes = Mailboxes.new({
   load = function(mailbox, callback, page) return mailbox_loader(mailbox, callback, page) end,
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
   on_page = function(page, err, records)
      if err then
         vim.notify("Zenvoy: " .. err, vim.log.levels.ERROR)
      elseif #records == 0 and page > state.current_page then
         vim.notify("Zenvoy: this is the last page", vim.log.levels.INFO)
      else
         show_page(page, records)
      end
   end,
})

-- n and N count from a page still loading, so n then N stays and N again goes back
-- further. A next page is asked for only after a full one.
local function change_page(step)
   if not state.is_open or not mailbox_loader then return end
   local loading = mailboxes:loading_page()
   if loading == false then return end -- A whole mailbox is loading.
   local shown, listed = state.current_page, #state.envelopes
   local target = (loading or shown) + step
   if target == shown then
      mailboxes:cancel_page()
   elseif target < 1 then
      if listed > 0 then vim.notify("Zenvoy: this is the first page", vim.log.levels.INFO) end
   elseif target > shown + 1 then
      return
   elseif target > shown and listed < config.get().himalaya.page_size then
      if listed > 0 then vim.notify("Zenvoy: this is the last page", vim.log.levels.INFO) end
   else
      mailboxes:page(state.current_folder, target)
   end
end

local function select_mailbox(options)
   local popup = state.sidebar_popup
   if not mailbox_loader or not state.is_open or not popup or not popup.winid
      or not vim.api.nvim_win_is_valid(popup.winid) then
      return
   end
   local selected = state.mailboxes[vim.api.nvim_win_get_cursor(popup.winid)[1]]
   if selected then mailboxes:select(selected.id, options) end
end

local function clear_session()
   shape, settling, deferred, windows, listing_cursor = nil, nil, nil, {}, nil
   pcall(vim.api.nvim_del_augroup_by_name, WINDOWS_GROUP)
   cancel_message()
   mailboxes:clear()
   if composer then composer:detach(); composer = nil end
   -- After the composer is gone, so a cancelled confirmation cannot refocus it.
   dialog.close()
   help.close()
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
   on_show_image = function() show_image() end,
   on_reader = reader_action,
   on_help = function() help.open(config.get().keymaps) end,
   on_page = change_page,
})

-- Actions on links, images and attachments are mapped in the message pane only, so the
-- same keys keep their usual meaning in the sidebar and the email list.
local message_only = {
   show_image = true, open_link = true, save_attachment = true, toggle_view = true,
   next_item = true, previous_item = true, toggle_fullscreen = true,
}

-- Page keys act on the email list, so `n` and `N` still repeat searches in the other panes.
local listing_only = { next_page = true, previous_page = true }

local function apply_keymaps(popup)
   local mappings = {}
   for lhs, action in pairs(config.get().keymaps) do
      if (popup == state.email_popup or not message_only[action])
         and (popup == state.listing_popup or not listing_only[action]) then
         mappings[lhs] = action
      end
   end
   keymap.apply(popup.bufnr, mappings, commands)
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

---@param downloader fun(id: string, mailbox: string?, ids: string[], directory: string?, callback: fun(err: string?, files: table[]?)): ZenvoyRequest?
function M.set_attachment_downloader(downloader)
   attachment_downloader = downloader
end

function M.set_composer(operations)
   if composer then composer:detach() end
   composer = require("zenvoy.ui.composer").new({
      prepare_reply = operations.prepare_reply,
      prepare_forward = operations.prepare_forward,
      send = operations.send,
      activity = function(label) return activity:start(label) end,
      notify = vim.notify,
      input = function(options, callback) vim.ui.input(options, callback) end,
      -- The form covers the Zenvoy window exactly, like a compose page.
      bounds = function()
         local winid = state.layout and state.layout.winid
         if not winid or not vim.api.nvim_win_is_valid(winid) then return nil end
         local row, col = unpack(vim.api.nvim_win_get_position(winid))
         return {
            row = row, col = col,
            width = vim.api.nvim_win_get_width(winid), height = vim.api.nvim_win_get_height(winid),
         }
      end,
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
      local title = (" ■ Emails (%d) · Page %d ■ "):format(#state.envelopes, state.current_page)
      state.listing_popup.border:set_text("top", title, "center")
      envelope.render(state.listing_popup.bufnr, state.envelopes)
      if cursor then
         cursor[1] = math.max(1, math.min(cursor[1], #state.envelopes))
         vim.api.nvim_win_set_cursor(popup.winid, cursor)
      end
   end
end

function M.create()
   if state.is_open then
      -- An email over the whole window hides the list.
      focus(state.listing_popup.winid and state.listing_popup or state.email_popup)
      return state.layout
   end

   state.sidebar_popup = layout.create_popup("Folders")
   state.listing_popup = layout.create_popup("Emails")
   state.email_popup = layout.create_popup("", {
      wrap = true, linebreak = true, breakindent = true, cursorline = false,
      foldmethod = "manual", foldenable = true, foldlevel = 0, foldcolumn = "0",
      foldtext = "v:lua.require'zenvoy.ui.message'.foldtext()", fillchars = "fold: ,eob: ",
   })
   state.email_visible, state.email_fullscreen = false, false

   local main = Layout(
      {
         position = "50%",
         relative = "editor",
         size = {
            width = "90%",
            height = "80%",
         },
      },
      create_box("list")
   )

   highlights.setup()
   state.layout = main
   main:mount()
   state.is_open = true
   shape, deferred, listing_cursor = "list", nil, nil
   settle()
   track_windows(main)
   attach_activity()
   -- Closing any Zenvoy window from outside (`:q`, `<C-w>c`) ends the session; panes
   -- hidden by a layout change do not.
   vim.api.nvim_create_autocmd("WinClosed", {
      group = vim.api.nvim_create_augroup(WINDOWS_GROUP, { clear = true }),
      callback = function(args)
         if switching or state.layout ~= main or not windows[tonumber(args.match)] then return end
         M.close(true)
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

   -- Like a browser status bar: show the destination of the link under the cursor.
   vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = state.email_popup.bufnr,
      callback = function()
         if state.layout == main and state.email_popup then show_status(item_under_cursor()) end
      end,
   })

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

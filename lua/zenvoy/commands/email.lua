local M = {}

---@class ZenvoyCommandContext
---@field state table
---@field create_box fun(): table
---@field update_layout? fun() Apply the requested pane visibility.
---@field focus fun(popup: table)
---@field current_buffer fun(): integer
---@field notify fun(message: string, level?: integer)
---@field on_close? fun() Release resources owned by the UI session.
---@field selected_envelope fun(): table? Return the envelope under the listing cursor.
---@field on_open_email? fun(envelope: table)
---@field on_hide_email? fun() Cancel work owned by the message pane.
---@field on_compose? fun(options: table) Open the new-message or reply form.
---@field request_close? fun(done: function) Guard session closure with an open composer.
---@field on_select_mailbox? fun(options?: table) Load the selected sidebar row.
---@field on_show_image? fun() Render the image under the message cursor.
---@field on_reader? fun(action: string) Act on the item under the message cursor.
---@field on_help? fun() Show the keybindings.
---@field on_page? fun(step: integer) Show the next (1) or previous (-1) page of emails.

---@param context ZenvoyCommandContext
---@return table
function M.create(context)
   local state = context.state

   local function update_layout()
      if context.update_layout then
         context.update_layout()
      else
         state.layout:update(context.create_box())
      end
   end

   local function show_email()
      if not state.layout then
         return
      end
      local selected = context.selected_envelope()
      if not selected then return end

      if not state.email_visible then
         -- Every email opens below the list; z shows it over the whole window.
         state.email_visible, state.email_fullscreen = true, false
         update_layout()
      end

      context.focus(state.email_popup)
      if context.on_open_email then context.on_open_email(selected) end
   end

   local function hide_email()
      if not state.layout or not state.email_visible then
         return
      end

      if context.on_hide_email then context.on_hide_email() end
      state.email_visible = false
      update_layout()
      context.focus(state.listing_popup)
   end

   -- Show the opened email over the whole window, or below the list again.
   local function toggle_fullscreen()
      if not state.layout or not state.email_visible then return end
      state.email_fullscreen = not state.email_fullscreen
      update_layout()
      context.focus(state.email_popup)
   end

   local function prepare(options)
      local selected = context.selected_envelope()
      if not selected or not context.on_compose then return end
      context.on_compose(vim.tbl_extend("force", { id = selected.id, mailbox = state.current_folder }, options))
   end

   local function reader(action)
      return function()
         if context.on_reader then context.on_reader(action) end
      end
   end

   return {
      show_email = show_email,
      hide_email = hide_email,
      toggle_fullscreen = toggle_fullscreen,
      compose = function()
         if context.on_compose then context.on_compose({}) end
      end,
      reply = function() prepare({ all = false }) end,
      reply_all = function() prepare({ all = true }) end,
      forward = function() prepare({ forward = true }) end,
      open_link = reader("open_link"),
      save_attachment = reader("save_attachment"),
      toggle_view = reader("toggle_view"),
      next_item = reader("next_item"),
      previous_item = reader("previous_item"),
   }
end

return M

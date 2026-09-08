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
         state.email_visible = true
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

   local function reply(all)
      local selected = context.selected_envelope()
      if not selected or not context.on_compose then return end
      context.on_compose({ id = selected.id, mailbox = state.current_folder, all = all })
   end

   return {
      show_email = show_email,
      hide_email = hide_email,
      compose = function()
         if context.on_compose then context.on_compose({}) end
      end,
      reply = function() reply(false) end,
      reply_all = function() reply(true) end,
   }
end

return M

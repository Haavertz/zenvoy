local M = {}

---@param context ZenvoyCommandContext
---@param email_commands table
---@return table
function M.create(context, email_commands)
   local state = context.state

   local function close_now()
      if context.on_close then context.on_close() end
      local active_layout = state.layout

      if not active_layout then
         return
      end

      state.is_open = false
      state.email_visible = false
      state.layout = nil
      state.sidebar_popup = nil
      state.listing_popup = nil
      state.email_popup = nil
      state.open_envelope = nil

      active_layout:unmount()
   end

   local function close(force)
      if not force and context.request_close then
         context.request_close(close_now)
      else
         close_now()
      end
   end

   local function focus_sidebar()
      -- An email over the whole window hides the folders: show them again.
      if state.email_visible and state.email_fullscreen then email_commands.toggle_fullscreen() end
      context.focus(state.sidebar_popup)
      if context.on_select_mailbox then context.on_select_mailbox() end
   end

   local function close_or_back()
      if state.email_visible then
         email_commands.hide_email()
         return
      end

      close()
   end

   local function enter()
      local current_buffer = context.current_buffer()

      if state.sidebar_popup and current_buffer == state.sidebar_popup.bufnr then
         if context.on_select_mailbox then context.on_select_mailbox({ immediate = true, retry = true }) end
         context.focus(state.listing_popup)
      elseif state.listing_popup and current_buffer == state.listing_popup.bufnr then
         email_commands.show_email()
      elseif state.email_popup and current_buffer == state.email_popup.bufnr and context.on_reader then
         context.on_reader("activate")
      end
   end

   return {
      close = close,
      close_or_back = close_or_back,
      enter = enter,
      focus_sidebar = focus_sidebar,
      show_image = function()
         if context.on_show_image then context.on_show_image() end
      end,
      help = function()
         if context.on_help then context.on_help() end
      end,
      next_page = function()
         if context.on_page then context.on_page(1) end
      end,
      previous_page = function()
         if context.on_page then context.on_page(-1) end
      end,
   }
end

return M

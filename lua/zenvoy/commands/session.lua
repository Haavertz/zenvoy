local M = {}

---@param context ZenvoyCommandContext
---@param email_commands table
---@return table
function M.create(context, email_commands)
   local state = context.state

   local function close()
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

      active_layout:unmount()
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
         context.focus(state.listing_popup)
      elseif state.listing_popup and current_buffer == state.listing_popup.bufnr then
         email_commands.show_email()
      end
   end

   return {
      close = close,
      close_or_back = close_or_back,
      enter = enter,
   }
end

return M

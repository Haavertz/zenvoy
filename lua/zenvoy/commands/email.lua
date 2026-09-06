local M = {}

---@class ZenvoyCommandContext
---@field state table
---@field create_box fun(): table
---@field focus fun(popup: table)
---@field current_buffer fun(): integer
---@field notify fun(message: string, level?: integer)

---@param context ZenvoyCommandContext
---@return table
function M.create(context)
   local state = context.state

   local function show_email()
      if not state.layout then
         return
      end

      if not state.email_visible then
         state.email_visible = true
         state.layout:update(context.create_box())
      end

      context.focus(state.email_popup)
   end

   local function hide_email()
      if not state.layout or not state.email_visible then
         return
      end

      state.email_visible = false
      state.layout:update(context.create_box())
      context.focus(state.listing_popup)
   end

   -- local function notify_not_implemented(action)
   --    context.notify(string.format("Zenvoy: %s is not implemented yet", action), vim.log.levels.INFO)
   -- end

   return {
      show_email = show_email,
      hide_email = hide_email,
      -- compose = function()
      --    notify_not_implemented("compose")
      -- end,
      -- reply = function()
      --    notify_not_implemented("reply")
      -- end,
   }
end

return M

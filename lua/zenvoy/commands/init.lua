local email = require("zenvoy.commands.email")
local session = require("zenvoy.commands.session")

local M = {}

---@param context ZenvoyCommandContext
---@return table
function M.create(context)
   local email_commands = email.create(context)
   local session_commands = session.create(context, email_commands)

   return {
      close = session_commands.close,
      close_or_back = session_commands.close_or_back,
      enter = session_commands.enter,
      show_image = session_commands.show_image,
      show_email = email_commands.show_email,
      hide_email = email_commands.hide_email,
      toggle_fullscreen = email_commands.toggle_fullscreen,
      help = session_commands.help,
      compose = email_commands.compose,
      reply = email_commands.reply,
      reply_all = email_commands.reply_all,
      forward = email_commands.forward,
      open_link = email_commands.open_link,
      save_attachment = email_commands.save_attachment,
      toggle_view = email_commands.toggle_view,
      next_item = email_commands.next_item,
      previous_item = email_commands.previous_item,
      focus_sidebar = session_commands.focus_sidebar,
   }
end

return M

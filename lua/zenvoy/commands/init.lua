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
      show_email = email_commands.show_email,
      hide_email = email_commands.hide_email,
      -- compose = email_commands.compose,
      -- reply = email_commands.reply,
   }
end

return M

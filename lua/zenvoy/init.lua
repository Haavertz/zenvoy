local config = require("zenvoy.config")
local process = require("zenvoy.core.process")
local state = require("zenvoy.state")
local welcome = require("zenvoy.ui.welcome")
local layout = require("zenvoy.ui")

local M = {}
local state_file = vim.fn.stdpath("data") .. "/voy_seen"

function M.setup(opts)
   config.setup(opts)
end

function M.open()
   if state.is_open then
      return nil
   end

   local job = process.run({
      on_success = function(response)
         layout.set_mailboxes(response.mailboxes)
      end,
      on_error = function(message)
         vim.notify("Zenvoy: " .. message, vim.log.levels.ERROR)
      end,
   })

   if vim.fn.filereadable(state_file) == 0 then
      welcome.create(function()
         layout.create()
      end)
      vim.fn.writefile({ "seen" }, state_file)
   else
      layout.create()
   end

   return job
end

function M.close()
   layout.close()
end

return M

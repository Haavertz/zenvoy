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

   local finish = layout.start_activity({ "Loading sidebar", "Loading emails" })
   local function on_error(message)
      if finish() then vim.notify("Zenvoy: " .. message, vim.log.levels.ERROR) end
   end

   local ok, job = pcall(process.run, {
      on_success = function(response)
         if not finish() then return end
         layout.set_mailboxes(response.mailboxes)
         layout.set_envelopes(response.envelopes)
      end,
      on_error = on_error,
   })
   if not ok then on_error(job) end

   if vim.fn.filereadable(state_file) == 0 then
      welcome.create(function()
         layout.create()
      end)
      vim.fn.writefile({ "seen" }, state_file)
   else
      layout.create()
   end

   return ok and job or nil
end

function M.close()
   layout.close()
end

return M

local config = require("zenvoy.config")
local Process = require("zenvoy.core.process")
local Client = require("zenvoy.himalaya.client")
local LoadMail = require("zenvoy.application.load_mail")
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

   state.current_folder, state.current_page = nil, 1
   layout.set_mailboxes({})
   layout.set_envelopes({})

   local finish = layout.start_activity({ "Loading sidebar", "Loading emails" })
   local function on_error(message)
      if finish() then vim.notify("Zenvoy: " .. message, vim.log.levels.ERROR) end
   end

   local options = config.get().himalaya
   local process = Process.new({ timeout = options.timeout })
   local client = Client.new(process, options)
   local loader = LoadMail.new(client)
   layout.set_message_reader(function(id, callback, mailbox)
      return client:read_message(id, mailbox, callback, { seen = true })
   end)
   layout.set_mailbox_loader(function(mailbox, callback)
      return client:list_envelopes(callback, mailbox)
   end)
   layout.set_composer({
      prepare_reply = function(id, mailbox, all, callback)
         return client:prepare_reply(id, mailbox, all, callback)
      end,
      send = function(draft, callback)
         return client:send_message(draft, callback)
      end,
   })
   local ok, request = pcall(loader.run, loader, {
      on_success = function(response)
         if not finish() then return end
         layout.set_mailboxes(response.mailboxes)
         layout.set_envelopes(response.envelopes)
      end,
      on_error = on_error,
   })
   if ok then
      local pending = request
      request = {
         cancel = function()
            finish()
            pending:cancel()
         end,
      }
      layout.track_request(request)
   else
      on_error(request)
   end

   if vim.fn.filereadable(state_file) == 0 then
      welcome.create(function()
         layout.create()
      end)
      vim.fn.writefile({ "seen" }, state_file)
   else
      layout.create()
   end

   return ok and request or nil
end

function M.close()
   layout.close()
end

return M

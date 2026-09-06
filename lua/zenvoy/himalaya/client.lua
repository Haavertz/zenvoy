local response = require("zenvoy.himalaya.response")

---@class ZenvoyMailbox
---@field id string Backend-native identity, preserved separately from the rendered label.
---@field name? string
---@field total? integer
---@field unread? integer

---@class ZenvoyEnvelope
---@field id string
---@field subject? string
---@field date? string
---@field flags? table[]|string[]
---@field from? table[]
---@field to? table[]
---@field size? integer

---@class ZenvoyMailClient
---@field list_mailboxes fun(self: ZenvoyMailClient, callback: fun(err: string?, records: ZenvoyMailbox[]?)): ZenvoyRequest?
---@field list_envelopes fun(self: ZenvoyMailClient, callback: fun(err: string?, records: ZenvoyEnvelope[]?)): ZenvoyRequest?

---@class ZenvoyHimalayaClient: ZenvoyMailClient
---@field process ZenvoyProcess
---@field executable string
---@field page_size integer
local Client = {}
Client.__index = Client

---@param process ZenvoyProcess
---@param options? { executable?: string, page_size?: integer }
---@return ZenvoyHimalayaClient
function Client.new(process, options)
   options = options or {}
   return setmetatable({
      process = process,
      executable = options.executable or "himalaya",
      page_size = options.page_size or 50,
   }, Client)
end

---@private
function Client:_list(collection, arguments, callback)
   local command = { self.executable }
   vim.list_extend(command, arguments)
   vim.list_extend(command, { "--json", "--log-level", "off" })

   return self.process:run(command, function(err, output)
      if err then
         callback("List Himalaya " .. collection .. ": " .. err)
         return
      end
      local records, decode_error = response.decode(output, collection)
      callback(decode_error, records)
   end)
end

---@param callback fun(err: string?, records: ZenvoyMailbox[]?)
---@return ZenvoyRequest
function Client:list_mailboxes(callback)
   return self:_list("mailboxes", { "mailbox", "list" }, callback)
end

---@param callback fun(err: string?, records: ZenvoyEnvelope[]?)
---@return ZenvoyRequest
function Client:list_envelopes(callback)
   return self:_list("envelopes", { "envelope", "list", "-s", tostring(self.page_size) }, callback)
end

return Client

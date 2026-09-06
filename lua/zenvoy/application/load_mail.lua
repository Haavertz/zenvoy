---@class ZenvoyInitialMail
---@field mailboxes ZenvoyMailbox[]
---@field envelopes ZenvoyEnvelope[]

---@class ZenvoyLoadMail
---@field client ZenvoyMailClient
local LoadMail = {}
LoadMail.__index = LoadMail

---@param client ZenvoyMailClient
---@return ZenvoyLoadMail
function LoadMail.new(client)
   return setmetatable({ client = client }, LoadMail)
end

---Load both collections concurrently and publish one complete result.
---Each run owns its state; cancelling it cannot affect another run.
---@param callbacks { on_success: fun(response: ZenvoyInitialMail), on_error: fun(err: string) }
---@return ZenvoyRequest
function LoadMail:run(callbacks)
   local stopped = false
   local pending, completed, response = {}, {}, {}
   local request = {}

   local function cancel_pending()
      for name, child in pairs(pending) do
         if not completed[name] then child:cancel() end
      end
   end

   function request:cancel()
      if stopped then return end
      stopped = true
      cancel_pending()
   end

   local function receive(name, err, records)
      if stopped or completed[name] then return end
      completed[name] = true
      if err then
         stopped = true
         cancel_pending()
         callbacks.on_error(err)
         return
      end

      response[name] = records
      if completed.mailboxes and completed.envelopes then
         stopped = true
         callbacks.on_success(response)
      end
   end

   for _, name in ipairs({ "mailboxes", "envelopes" }) do
      if stopped then break end
      pending[name] = self.client["list_" .. name](self.client, function(err, records)
         receive(name, err, records)
      end)
   end
   return request
end

return LoadMail

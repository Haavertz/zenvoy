-- Owns debounced mailbox requests and page changes. Rendering and backend operations
-- are injected.
local Mailboxes = {}
Mailboxes.__index = Mailboxes

function Mailboxes.new(options)
   return setmetatable({ options = options }, Mailboxes)
end

function Mailboxes:cancel()
   local pending = self.pending
   self.pending = nil
   if not pending then return end
   if pending.timer then
      pending.timer:stop()
      pending.timer:close()
      pending.timer = nil
   end
   if pending.finish then pending.finish() end
   if pending.request then pending.request:cancel() end
end

function Mailboxes:clear()
   self:cancel()
   self.mailbox, self.status = nil, nil
end

function Mailboxes:dispatch(pending)
   if self.pending ~= pending or pending.started then return end
   pending.started = true
   if pending.timer then
      pending.timer:stop()
      pending.timer:close()
      pending.timer = nil
   end
   local function receive(err, records)
      if self.pending ~= pending then return end
      self.pending = nil
      pending.finish()
      if pending.page then
         -- The selected mailbox stays loaded whatever happens to one of its pages.
         self.options.on_page(pending.page, err, records)
         return
      end
      self.status = err and "failed" or "ready"
      if err then self.options.on_error(err) else self.options.on_result(records) end
   end
   local ok, request = pcall(self.options.load, pending.mailbox, receive, pending.page)
   if ok then pending.request = request else receive(tostring(request)) end
end

---Load another page of the shown mailbox (nil is Himalaya's inbox), replacing a page
---change still loading. The shown emails stay until the page arrives.
---@param mailbox string?
---@param page integer
function Mailboxes:page(mailbox, page)
   self:cancel()
   local pending = { mailbox = mailbox, page = page, finish = self.options.activity("Loading page " .. page) }
   self.pending = pending
   self:dispatch(pending)
end

---The page being loaded: nil when idle, false while a whole mailbox loads.
---@return integer|false|nil
function Mailboxes:loading_page()
   local pending = self.pending
   if not pending then return nil end
   return pending.page or false
end

function Mailboxes:cancel_page()
   if self.pending and self.pending.page then self:cancel() end
end

function Mailboxes:select(mailbox, options)
   options = options or {}
   if self.mailbox == mailbox then
      if self.pending then
         if options.immediate then self:dispatch(self.pending) end
         return
      end
      if self.status ~= "failed" or not options.retry then return end
   end

   self:cancel()
   self.mailbox, self.status = mailbox, "loading"
   self.options.on_select(mailbox)
   local pending = { mailbox = mailbox, finish = self.options.activity("Loading emails") }
   self.pending = pending
   if options.immediate then return self:dispatch(pending) end
   pending.timer = vim.uv.new_timer()
   pending.timer:start(150, 0, vim.schedule_wrap(function() self:dispatch(pending) end))
end

return Mailboxes

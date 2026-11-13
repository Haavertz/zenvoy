local response = require("zenvoy.himalaya.response")
local message_response = require("zenvoy.himalaya.message")
local Draft = require("zenvoy.himalaya.draft")

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
---@field list_envelopes fun(self: ZenvoyMailClient, callback: fun(err: string?, records: ZenvoyEnvelope[]?), mailbox?: string, page?: integer): ZenvoyRequest?
---@field read_message fun(self: ZenvoyMailClient, id: string, mailbox: string?, callback: fun(err: string?, message: ZenvoyMessage?), options?: { seen?: boolean }): ZenvoyRequest?
---@field prepare_reply fun(self: ZenvoyMailClient, id: string, mailbox: string?, reply_all: boolean, callback: fun(err: string?, draft: ZenvoyDraft?)): ZenvoyRequest?
---@field prepare_forward fun(self: ZenvoyMailClient, id: string, mailbox: string?, callback: fun(err: string?, draft: ZenvoyDraft?)): ZenvoyRequest?
---@field send_message fun(self: ZenvoyMailClient, draft: ZenvoyDraft, callback: fun(err: string?)): ZenvoyRequest?
---@field download_attachments fun(self: ZenvoyMailClient, id: string, mailbox: string?, ids: string[], directory: string?, callback: fun(err: string?, files: table[]?)): ZenvoyRequest?

---@class ZenvoyAttachment
---@field id string MIME part position accepted by `himalaya attachment download`.
---@field name string
---@field mime? string
---@field size? integer Decoded size in bytes.
---@field inline boolean
---@field cid? string
---@field referenced boolean Shown inline by the HTML body through `cid:`.

---@class ZenvoyMessage
---@field subject? string
---@field from table[]
---@field to table[]
---@field cc table[]
---@field reply_to table[]
---@field date? integer Unix timestamp.
---@field body string Readable text used for quoting.
---@field text_parts table[] Ordered { text } | { html } | { image } segments of the text alternative.
---@field html_parts table[] The same for the HTML alternative.
---@field has_html boolean
---@field images table[]
---@field attachments ZenvoyAttachment[]

---@class ZenvoyHimalayaClient: ZenvoyMailClient
---@field process ZenvoyProcess
---@field executable string
---@field page_size integer
local Client = {}
Client.__index = Client

-- Sending large attachments can take longer than ordinary commands. A timeout would
-- invite a manual retry of a message that may already have been delivered.
local TRANSFER_TIMEOUT = 5 * 60 * 1000

---@param process ZenvoyProcess
---@param options? { executable?: string, page_size?: integer, temporary_directory?: fun(): string }
---@return ZenvoyHimalayaClient
function Client.new(process, options)
   options = options or {}
   return setmetatable({
      process = process,
      executable = options.executable or "himalaya",
      page_size = options.page_size or 40,
      temporary_directory = options.temporary_directory or vim.fn.tempname,
   }, Client)
end

-- With --json, Himalaya reports failures as {"error": "..."}.
local function backend_error(err)
   if type(err) ~= "string" or not err:match("^%s*{") then return err end
   local ok, value = pcall(vim.json.decode, err, { luanil = { object = true } })
   if ok and type(value) == "table" and type(value.error) == "string" then return value.error end
   return err
end

local function transfer_timeout(process)
   return math.max(type(process.timeout) == "number" and process.timeout or 0, TRANSFER_TIMEOUT)
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
---@param mailbox? string
---@param page? integer Starts at 1, the most recent envelopes; a page past the end is empty.
---@return ZenvoyRequest
function Client:list_envelopes(callback, mailbox, page)
   local command = { "envelope", "list", "-s", tostring(self.page_size) }
   if page and page > 1 then vim.list_extend(command, { "--page", tostring(page) }) end
   if mailbox then vim.list_extend(command, { "--mailbox", mailbox }) end
   return self:_list("envelopes", command, callback)
end

---@param id string
---@param mailbox string? Omit to use the same default mailbox as list_envelopes.
---@param callback fun(err: string?, message: ZenvoyMessage?)
---@param options? { seen?: boolean }
---@return ZenvoyRequest
function Client:read_message(id, mailbox, callback, options)
   local command = { self.executable, "message", "read" }
   if mailbox then vim.list_extend(command, { "--mailbox", mailbox }) end
   if options and options.seen == true then command[#command + 1] = "--seen" end
   vim.list_extend(command, { "--json", "--log-level", "off", "--", id })
   return self.process:run(command, function(err, output)
      if err then
         callback("Read Himalaya message: " .. err)
         return
      end
      local message, decode_error = message_response.decode(output)
      callback(decode_error, message)
   end)
end

-- Each compound operation owns its children. This also works with injected
-- processes that finish synchronously, before returning their request handles.
local function operation(callback)
   local pending, completed, stopped = {}, {}, false
   local request = {}
   local function cancel_pending()
      for name, child in pairs(pending) do
         if not completed[name] and child then child:cancel() end
      end
   end
   function request:cancel()
      if stopped then return end
      stopped = true
      cancel_pending()
   end
   local function finish(err, value)
      if stopped then return end
      stopped = true
      if err then cancel_pending() end
      callback(err, value)
   end
   local function start(name, spawn, receive)
      if stopped then return end
      pending[name] = spawn(function(err, value)
         if stopped or completed[name] then return end
         completed[name] = true
         if err then finish(err) else receive(value, finish) end
      end)
   end
   return request, start, finish
end

---@param id string
---@param mailbox string?
---@param reply_all boolean
---@param callback fun(err: string?, draft: ZenvoyDraft?)
---@return ZenvoyRequest
function Client:prepare_reply(id, mailbox, reply_all, callback)
   local request, start, finish = operation(callback)
   local source, preview
   local function ready()
      if not source or not preview then return end
      local draft, err = Draft.reply(source, preview, reply_all)
      if draft then
         draft.reply_context.id, draft.reply_context.mailbox = id, mailbox
      end
      finish(err, draft)
   end
   start("source", function(receive)
      return self:read_message(id, mailbox, receive)
   end, function(value) source = value; ready() end)
   start("preview", function(receive)
      local command = { self.executable, "message", "reply" }
      if mailbox then vim.list_extend(command, { "--mailbox", mailbox }) end
      vim.list_extend(command, { "--body=", "--log-level", "off", "--", id })
      return self.process:run(command, function(err, output)
         receive(err and ("Prepare Himalaya reply: " .. err), output)
      end)
   end, function(value) preview = value; ready() end)
   return request
end

---Download attachment parts. Himalaya sanitizes file names and never overwrites files.
---@param id string Message identity.
---@param mailbox string?
---@param ids string[] Attachment part IDs; all attachments when empty.
---@param directory string? Destination; Himalaya's downloads-dir when nil.
---@param callback fun(err: string?, files: { id: string, path: string, filename?: string, mime?: string, size?: integer }[]?)
---@return ZenvoyRequest
function Client:download_attachments(id, mailbox, ids, directory, callback)
   local command = { self.executable, "attachment", "download" }
   if mailbox then vim.list_extend(command, { "--mailbox", mailbox }) end
   if directory then command[#command + 1] = "--dir=" .. directory end
   vim.list_extend(command, { "--json", "--log-level", "off", "--", id })
   vim.list_extend(command, ids or {})
   return self.process:run(command, function(err, output)
      if err then
         callback("Download Himalaya attachment: " .. backend_error(err))
         return
      end
      local files, decode_error = response.decode(output, "attachments")
      if decode_error then
         callback(decode_error)
         return
      end
      for _, file in ipairs(files) do
         if type(file.path) ~= "string" or file.path == "" then
            callback("Invalid Himalaya JSON (attachments): missing download path")
            return
         end
      end
      callback(nil, files)
   end, { timeout = transfer_timeout(self.process) })
end

---Read the original and download its attachments for an inline forward.
---@param id string
---@param mailbox string?
---@param callback fun(err: string?, draft: ZenvoyDraft?)
---@return ZenvoyRequest
function Client:prepare_forward(id, mailbox, callback)
   local request, start, finish = operation(callback)
   start("source", function(receive)
      return self:read_message(id, mailbox, receive)
   end, function(source)
      local ids = {}
      for _, attachment in ipairs(source.attachments or {}) do ids[#ids + 1] = attachment.id end
      if #ids == 0 then
         local draft, err = Draft.forward(source, {})
         finish(err, draft)
         return
      end
      -- Neovim removes its private temporary directory on exit.
      local directory = self.temporary_directory()
      start("attachments", function(receive)
         return self:download_attachments(id, mailbox, ids, directory, receive)
      end, function(files)
         local paths = {}
         for _, file in ipairs(files) do paths[#paths + 1] = file.path end
         local draft, err = Draft.forward(source, paths)
         finish(err, draft)
      end)
   end)
   return request
end

---@param draft ZenvoyDraft
---@param callback fun(err: string?)
---@return ZenvoyRequest
function Client:send_message(draft, callback)
   local request, start, finish = operation(callback)
   local validated, validation_error = Draft.validate(draft)
   if validation_error then finish(validation_error); return request end
   local command = { self.executable, "message", "compose" }
   for _, field in ipairs({ "to", "cc", "bcc" }) do
      if validated[field] ~= "" then command[#command + 1] = "--" .. field .. "=" .. validated[field] end
   end
   command[#command + 1] = "--subject=" .. validated.subject
   for _, path in ipairs(validated.attachments) do command[#command + 1] = "--attach=" .. path end
   vim.list_extend(command, { "--log-level", "off" })
   local send_timeout = #validated.attachments > 0 and transfer_timeout(self.process) or nil
   start("compile", function(receive)
      -- Final composition appends the account's signature once. Native reply's
      -- body is never reused, so editing the original quotation cannot duplicate it.
      return self.process:run(command, function(err, output)
         receive(err and ("Compose Himalaya message: " .. err), output)
      end, { stdin = validated.body })
   end, function(output)
      local raw, err = Draft.apply_context(output, validated.reply_context)
      if err then finish(err); return end
      start("send", function(receive)
         return self.process:run({ self.executable, "message", "send", "--json", "--log-level", "off" },
            function(send_error, result)
               receive(send_error and ("Send Himalaya message: " .. backend_error(send_error)), result)
            end, { stdin = raw, timeout = send_timeout })
      end, function() finish() end)
   end)
   return request
end

return Client

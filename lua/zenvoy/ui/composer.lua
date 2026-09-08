local Layout = require("nui.layout")
local Popup = require("nui.popup")
local Text = require("nui.text")

local Composer = {}
Composer.__index = Composer

local fields = { "to", "cc", "bcc", "subject", "body" }
local titles = { to = "To", cc = "Cc", bcc = "Bcc", subject = "Subject", body = "Body" }

local function valid_window(winid)
   return winid and vim.api.nvim_win_is_valid(winid)
end

local function finish_activity(session)
   local finish = session.finish_activity
   session.finish_activity = nil
   if finish then finish() end
end

local function lock(session, locked)
   for _, name in ipairs(fields) do
      local bufnr = session.fields[name].bufnr
      if vim.api.nvim_buf_is_valid(bufnr) then
         vim.bo[bufnr].modifiable = not locked
         vim.bo[bufnr].readonly = locked
      end
   end
end

local function field_values(session)
   local draft = {}
   for _, name in ipairs(fields) do
      draft[name] = table.concat(vim.api.nvim_buf_get_lines(session.fields[name].bufnr, 0, -1, false), "\n")
   end
   return draft
end

local function snapshot(session)
   return vim.tbl_extend("force", vim.deepcopy(session.metadata), field_values(session))
end

local function validate(draft)
   for _, name in ipairs({ "to", "cc", "bcc", "subject" }) do
      if draft[name]:find("[\r\n%z]") then return titles[name] .. " must be a single line without control characters" end
   end
   if not (draft.to .. draft.cc .. draft.bcc):find("%S") then return "Add at least one recipient in To, Cc, or Bcc" end
end

local function has_changes(session)
   return not vim.deep_equal(session.baseline, field_values(session))
end

---@param options { prepare_reply?: function, send?: function, activity?: function, notify?: function, choose?: function }
function Composer.new(options)
   options = options or {}
   return setmetatable({
      prepare_reply = options.prepare_reply,
      send = options.send,
      activity = options.activity or function() return function() end end,
      notify = options.notify or vim.notify,
      choose = options.choose or vim.ui.select,
   }, Composer)
end

function Composer:is_open()
   return self.session ~= nil
end

function Composer:_focus(session, index, insert)
   if self.session ~= session then return end
   local popup = session.fields[fields[index]]
   if valid_window(popup.winid) then
      session.focused = index
      vim.api.nvim_set_current_win(popup.winid)
      if insert and session.phase == "editing" then vim.cmd.startinsert() end
   end
end

function Composer:_unmount(session)
   if self.session == session then self.session = nil end
   if session.preparation then
      local request = session.preparation
      session.preparation = nil
      request:cancel()
   end
   -- Delivery already dispatched is deliberately not cancelled: its outcome may
   -- already be committed remotely. Its callback still reports the final result.
   if session.phase ~= "sending" then finish_activity(session) end
   vim.cmd.stopinsert()
   session.layout:unmount()
   if valid_window(session.previous_win) then vim.api.nvim_set_current_win(session.previous_win) end
end

function Composer:detach()
   if self.session then self:_unmount(self.session) end
end

function Composer:request_close(done)
   local session = self.session
   if not session then
      if done then done() end
      return
   end
   if session.phase == "sending" then
      self.notify("Zenvoy: email is still being sent", vim.log.levels.INFO)
      return
   end
   if session.phase == "confirming" or session.phase == "discarding" then return end
   if not has_changes(session) then
      self:_unmount(session)
      if done then done() end
      return
   end

   session.phase = "discarding"
   local choice_token = {}
   session.choice_token = choice_token
   lock(session, true)
   vim.cmd.stopinsert()
   local ok, err = pcall(self.choose, { "Keep editing", "Discard" }, { prompt = "Discard this email?" }, function(choice)
      if self.session ~= session or session.phase ~= "discarding" or session.choice_token ~= choice_token then return end
      session.choice_token = nil
      if choice == "Discard" then
         self:_unmount(session)
         if done then done() end
      else
         session.phase = "editing"
         lock(session, false)
         self:_focus(session, session.focused, false)
      end
   end)
   if not ok and self.session == session and session.phase == "discarding" then
      session.phase = "editing"
      lock(session, false)
      self.notify("Zenvoy: " .. tostring(err), vim.log.levels.ERROR)
   end
end

function Composer:_send(session)
   if self.session ~= session or session.phase ~= "editing" then return end
   local draft = snapshot(session)
   local invalid = validate(draft)
   if invalid then
      self.notify("Zenvoy: " .. invalid, vim.log.levels.ERROR)
      return
   end
   session.phase = "confirming"
   local choice_token = {}
   session.choice_token = choice_token
   lock(session, true)
   vim.cmd.stopinsert()
   local ok, err = pcall(self.choose, { "Cancel", "Send" }, {
      prompt = "Send this email?",
   }, function(choice)
      if self.session ~= session or session.phase ~= "confirming" or session.choice_token ~= choice_token then return end
      session.choice_token = nil
      if choice ~= "Send" then
         session.phase = "editing"
         lock(session, false)
         self:_focus(session, session.focused, false)
         return
      end

      session.phase = "sending"
      local attempt = {}
      session.send_attempt = attempt
      lock(session, true)
      session.finish_activity = self.activity("Sending email")
      local function receive(send_error)
         if session.send_attempt ~= attempt or attempt.completed then return end
         attempt.completed = true
         session.phase = "editing"
         finish_activity(session)
         if send_error then
            if self.session == session then
               lock(session, false)
               self:_focus(session, session.focused, false)
            end
            self.notify("Zenvoy: " .. tostring(send_error), vim.log.levels.ERROR)
         else
            if self.session == session then self:_unmount(session) end
            self.notify("Zenvoy: email sent", vim.log.levels.INFO)
         end
      end
      if not self.send then
         receive("Email sender is not configured")
         return
      end
      local started, request = pcall(self.send, draft, receive)
      if not started then receive(tostring(request)) end
   end)
   if not ok and self.session == session and session.phase == "confirming" then
      session.phase = "editing"
      lock(session, false)
      self.notify("Zenvoy: " .. tostring(err), vim.log.levels.ERROR)
   end
end

function Composer:_prepare(session, options)
   session.finish_activity = self.activity("Preparing reply")
   local function receive(err, draft)
      if self.session ~= session or session.phase ~= "preparing" then return end
      session.preparation = nil
      finish_activity(session)
      session.phase = "editing"
      lock(session, false)
      if err or type(draft) ~= "table" then
         self.notify("Zenvoy: " .. tostring(err or "Invalid reply draft"), vim.log.levels.ERROR)
         self:_unmount(session)
         return
      end
      session.metadata = vim.deepcopy(draft)
      for _, name in ipairs(fields) do
         local text = type(draft[name]) == "string" and draft[name] or ""
         vim.api.nvim_buf_set_lines(session.fields[name].bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
         session.metadata[name] = nil
      end
      session.baseline = field_values(session)
      vim.api.nvim_win_set_cursor(session.fields.body.winid, { 1, 0 })
      self:_focus(session, #fields, true)
   end
   if not self.prepare_reply then
      receive("Reply preparation is not configured")
      return
   end
   local ok, request = pcall(self.prepare_reply, options.id, options.mailbox, options.all == true, receive)
   if not ok then
      receive(tostring(request))
   elseif self.session == session and session.phase == "preparing" then
      session.preparation = request
   end
end

---Open one editable draft. Passing an envelope identity prepares a threaded reply.
---@param options? { id?: string, mailbox?: string, all?: boolean }
function Composer:open(options)
   if self.session then
      self:_focus(self.session, self.session.focused, self.session.phase == "editing")
      return
   end
   options = options or {}
   local session = {
      fields = {}, metadata = {}, focused = 1,
      previous_win = vim.api.nvim_get_current_win(),
      phase = options.id and "preparing" or "editing",
   }
   self.session = session
   local boxes = {}
   for index, name in ipairs(fields) do
      local popup = Popup({
         relative = "editor", enter = false, focusable = true, zindex = 70,
         border = {
            style = "rounded",
            text = {
               top = Text(" " .. titles[name] .. " ", "FloatTitle"), top_align = "left",
               bottom = name == "body" and Text(" Tab/S-Tab fields  C-s send  Esc/q close ", "FloatTitle") or nil,
               bottom_align = "center",
            },
         },
         buf_options = {
            buftype = "nofile", bufhidden = "wipe", swapfile = false, undofile = false,
            modifiable = session.phase == "editing", readonly = session.phase ~= "editing",
            filetype = "zenvoy-compose-" .. name,
         },
         win_options = { wrap = true, linebreak = true, number = false, relativenumber = false, cursorline = false },
      })
      session.fields[name] = popup
      vim.b[popup.bufnr].zenvoy_compose_field = name
      boxes[#boxes + 1] = Layout.Box(popup, name == "body" and { grow = 1 } or { size = 3 })
      for _, mode in ipairs({ "n", "i" }) do
         for lhs, delta in pairs({ ["<Tab>"] = 1, ["<S-Tab>"] = -1 }) do
            vim.keymap.set(mode, lhs, function()
               self:_focus(session, (index - 1 + delta) % #fields + 1, mode == "i")
            end, { buffer = popup.bufnr, silent = true, nowait = true, desc = "Zenvoy: change compose field" })
         end
         vim.keymap.set(mode, "<C-s>", function() self:_send(session) end,
            { buffer = popup.bufnr, silent = true, desc = "Zenvoy: send email" })
      end
      for _, lhs in ipairs({ "q", "<Esc>" }) do
         vim.keymap.set("n", lhs, function()
            if self.session == session then self:request_close() end
         end, { buffer = popup.bufnr, silent = true, nowait = true, desc = "Zenvoy: close composer" })
      end
   end
   session.layout = Layout({
      relative = "editor", position = "50%",
      size = { width = "80%", height = math.max(17, math.floor((vim.o.lines - 2) * 0.85)) },
   }, Layout.Box(boxes, { dir = "col" }))
   session.layout:mount()
   session.baseline = field_values(session)
   for _, name in ipairs(fields) do
      vim.api.nvim_create_autocmd("WinClosed", {
         pattern = tostring(session.fields[name].winid), once = true,
         callback = function()
            if self.session == session then self:detach() end
         end,
      })
   end
   self:_focus(session, 1, session.phase == "editing")
   if options.id then self:_prepare(session, options) end
end

return Composer

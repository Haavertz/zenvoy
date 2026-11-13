local Layout = require("nui.layout")
local Popup = require("nui.popup")
local Text = require("nui.text")
local attachments = require("zenvoy.core.attachments")

local Composer = {}
Composer.__index = Composer

local fields = { "to", "cc", "bcc", "subject", "body", "attachments" }
local titles = {
   to = "To", cc = "Cc", bcc = "Bcc", subject = "Subject", body = "Body", attachments = "Attachments",
}
local field_index = {}
for index, name in ipairs(fields) do field_index[name] = index end
local namespace = vim.api.nvim_create_namespace("zenvoy-compose-attachments")
local MAX_ATTACHMENT_ROWS = 5
local HINT = " Tab/S-Tab fields  C-a attach  C-s send  Esc/q close "

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

local function attachment_lines(session)
   return vim.api.nvim_buf_get_lines(session.fields.attachments.bufnr, 0, -1, false)
end

---@param options { prepare_reply?: function, prepare_forward?: function, send?: function, activity?: function, notify?: function, choose?: function, input?: function }
function Composer.new(options)
   options = options or {}
   return setmetatable({
      prepare_reply = options.prepare_reply,
      prepare_forward = options.prepare_forward,
      send = options.send,
      activity = options.activity or function() return function() end end,
      notify = options.notify or vim.notify,
      choose = options.choose or vim.ui.select,
      input = options.input or vim.ui.input,
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

-- Short screens place Cc and Bcc side by side so the body keeps room.
local COMPACT_HEIGHT = 26

local function compact(session)
   return session.height < COMPACT_HEIGHT
end

-- One box per field; the attachments list grows with its content.
local function layout_box(session)
   local boxes = {}
   for _, name in ipairs(fields) do
      if name == "cc" and compact(session) then
         boxes[#boxes + 1] = Layout.Box({
            Layout.Box(session.fields.cc, { grow = 1 }),
            Layout.Box(session.fields.bcc, { grow = 1 }),
         }, { dir = "row", size = 3 })
      elseif name ~= "bcc" or not compact(session) then
         local size = { size = 3 }
         if name == "body" then
            size = { grow = 1 }
         elseif name == "attachments" then
            size = { size = session.attachment_rows + 2 }
         end
         boxes[#boxes + 1] = Layout.Box(session.fields[name], size)
      end
   end
   return Layout.Box(boxes, { dir = "col" })
end

function Composer:_resize(session)
   if self.session ~= session or not session.layout then return end
   local count = 0
   for _, line in ipairs(attachment_lines(session)) do
      if line:find("%S") then count = count + 1 end
   end
   -- Keep at least three body lines besides the one-line fields and the borders.
   local header_rows = (compact(session) and 3 or 4) * 3
   local available = session.height - header_rows - (3 + 2) - 2
   local rows = math.max(1, math.min(count, MAX_ATTACHMENT_ROWS, available))
   if rows == session.attachment_rows then return end
   session.attachment_rows = rows
   session.layout:update(layout_box(session))
end

---Show each file's size, or why it cannot be attached, and hide its directory.
function Composer:_decorate(session)
   local bufnr = session.fields.attachments.bufnr
   if not vim.api.nvim_buf_is_valid(bufnr) then return end
   vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
   local lines = attachment_lines(session)
   if #lines == 1 and lines[1] == "" then
      vim.api.nvim_buf_set_extmark(bufnr, namespace, 0, 0, {
         virt_text = { { "C-a attach a file, or type one path per line", "ZenvoyMuted" } },
         virt_text_pos = "overlay",
      })
      return
   end
   for index, line in ipairs(lines) do
      if line:find("%S") then
         local file, err = attachments.resolve(line)
         local note = file and { "  " .. (attachments.format_size(file.size) or ""), "ZenvoyMuted" }
            or { "  ✗ " .. tostring(err):gsub(":.*$", ""), "ZenvoyError" }
         vim.api.nvim_buf_set_extmark(bufnr, namespace, index - 1, 0, { virt_text = { note } })
         local directory = file and line:find("[/\\][^/\\]*$")
         if directory then
            local start = #line:match("^%s*")
            pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, index - 1, start, {
               end_col = directory, conceal = "",
            })
         end
      end
   end
end

function Composer:_refresh(session)
   if self.session ~= session then return end
   self:_decorate(session)
   self:_resize(session)
end

---Add a file chosen with completion in a prompt.
function Composer:_attach(session)
   if self.session ~= session or session.phase ~= "editing" then return end
   local return_to = session.focused
   local current = vim.api.nvim_get_current_win()
   for index, name in ipairs(fields) do
      if session.fields[name].winid == current then return_to = index end
   end
   vim.cmd.stopinsert()
   local default = (self.last_directory or vim.fn.getcwd()) .. "/"
   local ok, err = pcall(self.input, { prompt = "Attach file: ", default = default, completion = "file" },
      function(answer)
         if self.session ~= session or session.phase ~= "editing" then return end
         if answer and answer:find("%S") then
            local file, resolve_error = attachments.resolve(answer)
            if not file then
               self.notify("Zenvoy: " .. tostring(resolve_error), vim.log.levels.ERROR)
            else
               local lines, duplicate = attachment_lines(session), false
               for _, line in ipairs(lines) do
                  local existing = attachments.resolve(line)
                  if existing and existing.path == file.path then duplicate = true end
               end
               if not duplicate then
                  if #lines == 1 and lines[1] == "" then lines = {} end
                  lines[#lines + 1] = file.path
                  vim.api.nvim_buf_set_lines(session.fields.attachments.bufnr, 0, -1, false, lines)
                  self.last_directory = vim.fs.dirname(file.path)
                  self:_refresh(session)
               end
            end
         end
         self:_focus(session, return_to, false)
      end)
   if not ok then self.notify("Zenvoy: " .. tostring(err), vim.log.levels.ERROR) end
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
   local files, attachment_error = attachments.parse(vim.split(draft.attachments, "\n", { plain = true }))
   if not files then
      self.notify("Zenvoy: " .. attachment_error, vim.log.levels.ERROR)
      return
   end
   draft.attachments = {}
   for _, file in ipairs(files) do draft.attachments[#draft.attachments + 1] = file.path end
   local prompt = "Send this email?"
   if #files > 0 then
      prompt = ("Send this email with %d attachment%s (%s)?"):format(#files, #files == 1 and "" or "s",
         attachments.format_size(attachments.total_size(files)))
   end
   session.phase = "confirming"
   local choice_token = {}
   session.choice_token = choice_token
   lock(session, true)
   vim.cmd.stopinsert()
   local ok, err = pcall(self.choose, { "Cancel", "Send" }, {
      prompt = prompt,
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
   local forward = options.forward == true
   session.finish_activity = self.activity(forward and "Preparing forward" or "Preparing reply")
   local function receive(err, draft)
      if self.session ~= session or session.phase ~= "preparing" then return end
      session.preparation = nil
      finish_activity(session)
      session.phase = "editing"
      lock(session, false)
      if err or type(draft) ~= "table" then
         self.notify("Zenvoy: " .. tostring(err or "Invalid prepared draft"), vim.log.levels.ERROR)
         self:_unmount(session)
         return
      end
      session.metadata = vim.deepcopy(draft)
      for _, name in ipairs(fields) do
         local value = draft[name]
         if type(value) == "table" then value = table.concat(value, "\n") end
         local text = type(value) == "string" and value or ""
         vim.api.nvim_buf_set_lines(session.fields[name].bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
         session.metadata[name] = nil
      end
      session.baseline = field_values(session)
      self:_refresh(session)
      if forward then
         self:_focus(session, field_index.to, true)
      else
         vim.api.nvim_win_set_cursor(session.fields.body.winid, { 1, 0 })
         self:_focus(session, field_index.body, true)
      end
   end
   local prepare = forward and self.prepare_forward or self.prepare_reply
   if not prepare then
      receive((forward and "Forward" or "Reply") .. " preparation is not configured")
      return
   end
   local ok, request
   if forward then
      ok, request = pcall(prepare, options.id, options.mailbox, receive)
   else
      ok, request = pcall(prepare, options.id, options.mailbox, options.all == true, receive)
   end
   if not ok then
      receive(tostring(request))
   elseif self.session == session and session.phase == "preparing" then
      session.preparation = request
   end
end

---Open one editable draft. Passing an envelope identity prepares a threaded reply,
---or an inline forward with the original attachments when `forward` is set.
---@param options? { id?: string, mailbox?: string, all?: boolean, forward?: boolean }
function Composer:open(options)
   if self.session then
      self:_focus(self.session, self.session.focused, self.session.phase == "editing")
      return
   end
   options = options or {}
   local session = {
      fields = {}, metadata = {}, focused = 1, attachment_rows = 1,
      previous_win = vim.api.nvim_get_current_win(),
      phase = options.id and "preparing" or "editing",
      height = math.max(17, math.floor((vim.o.lines - 2) * 0.85)),
   }
   self.session = session
   for index, name in ipairs(fields) do
      local last = index == #fields
      local popup = Popup({
         relative = "editor", enter = false, focusable = true, zindex = 70,
         border = {
            style = "rounded",
            text = {
               top = Text(" " .. titles[name] .. " ", "FloatTitle"), top_align = "left",
               bottom = last and Text(HINT, "FloatTitle") or nil,
               bottom_align = "center",
            },
         },
         buf_options = {
            buftype = "nofile", bufhidden = "wipe", swapfile = false, undofile = false,
            modifiable = session.phase == "editing", readonly = session.phase ~= "editing",
            filetype = "zenvoy-compose-" .. name,
         },
         win_options = {
            wrap = name ~= "attachments", linebreak = true, number = false, relativenumber = false,
            cursorline = false, conceallevel = name == "attachments" and 2 or 0, concealcursor = "",
         },
      })
      session.fields[name] = popup
      vim.b[popup.bufnr].zenvoy_compose_field = name
      for _, mode in ipairs({ "n", "i" }) do
         for lhs, delta in pairs({ ["<Tab>"] = 1, ["<S-Tab>"] = -1 }) do
            vim.keymap.set(mode, lhs, function()
               self:_focus(session, (index - 1 + delta) % #fields + 1, mode == "i")
            end, { buffer = popup.bufnr, silent = true, nowait = true, desc = "Zenvoy: change compose field" })
         end
         vim.keymap.set(mode, "<C-s>", function() self:_send(session) end,
            { buffer = popup.bufnr, silent = true, desc = "Zenvoy: send email" })
         vim.keymap.set(mode, "<C-a>", function() self:_attach(session) end,
            { buffer = popup.bufnr, silent = true, desc = "Zenvoy: attach a file" })
      end
      for _, lhs in ipairs({ "q", "<Esc>" }) do
         vim.keymap.set("n", lhs, function()
            if self.session == session then self:request_close() end
         end, { buffer = popup.bufnr, silent = true, nowait = true, desc = "Zenvoy: close composer" })
      end
   end
   session.layout = Layout({
      relative = "editor", position = "50%",
      size = { width = "80%", height = session.height },
   }, layout_box(session))
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
   vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = session.fields.attachments.bufnr,
      callback = function() self:_refresh(session) end,
   })
   self:_decorate(session)
   self:_focus(session, 1, session.phase == "editing")
   if options.id then self:_prepare(session, options) end
end

return Composer

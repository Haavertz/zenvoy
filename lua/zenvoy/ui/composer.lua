-- The compose form: one frame over the Zenvoy window, like a webmail compose page.
-- Each field is its own scratch buffer in a borderless window placed inside the frame:
--
--   ┌──────────── ■ Reply ■ ────────────┐
--   │ To       alice@example.com        │
--   │ Cc                                │
--   │ Bcc                               │
--   │ Subject  Re: Hello                │
--   ├───────────────────────────────────┤
--   │ body…                             │
--   ├───────────────────────────────────┤
--   │ Files    report.pdf  1.2 MB       │
--   └── Tab/S-Tab fields  C-s send … ───┘
local attachments = require("zenvoy.core.attachments")
local dialog = require("zenvoy.ui.dialog")

local Composer = {}
Composer.__index = Composer

local fields = { "to", "cc", "bcc", "subject", "body", "attachments" }
local headers = { "to", "cc", "bcc", "subject" }
local labels = { to = "To", cc = "Cc", bcc = "Bcc", subject = "Subject", attachments = "Files" }
local field_index = {}
for index, name in ipairs(fields) do field_index[name] = index end
local namespace = vim.api.nvim_create_namespace("zenvoy-compose-attachments")
local frame_namespace = vim.api.nvim_create_namespace("zenvoy-compose-frame")
local MAX_ATTACHMENT_ROWS = 5
local MIN_BODY_ROWS = 3
local LABEL_WIDTH = 9 -- "Subject" and two spaces
-- Frame rows besides the body and the files: two borders, four headers and two rules.
local FIXED_ROWS = 8
local HINT = " Tab/S-Tab fields  C-a attach  C-s send  Esc/q close "
local SHORT_HINT = " C-s send  Esc/q close "
local sessions = 0

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
   for _, name in ipairs(headers) do
      if draft[name]:find("[\r\n%z]") then return labels[name] .. " must be a single line without control characters" end
   end
   if not (draft.to .. draft.cc .. draft.bcc):find("%S") then return "Add at least one recipient in To, Cc, or Bcc" end
end

local function has_changes(session)
   return not vim.deep_equal(session.baseline, field_values(session))
end

local function attachment_lines(session)
   return vim.api.nvim_buf_get_lines(session.fields.attachments.bufnr, 0, -1, false)
end

---Where the frame and each field go. Headers and files sit right of their labels and
---the body spans the frame between two rules.
---@param rect { row: integer, col: integer, width: integer, height: integer }
---@param attachment_rows integer
local function places(rect, attachment_rows)
   local body_rows = math.max(1, rect.height - FIXED_ROWS - attachment_rows)
   local inner_col, inner_width = rect.col + 2, math.max(1, rect.width - 4)
   local field_col, field_width = inner_col + LABEL_WIDTH, math.max(1, inner_width - LABEL_WIDTH)
   local result = {
      frame = { row = rect.row, col = rect.col, width = rect.width, height = FIXED_ROWS + body_rows + attachment_rows },
      body = { row = rect.row + #headers + 2, col = inner_col, width = inner_width, height = body_rows },
   }
   for index, name in ipairs(headers) do
      result[name] = { row = rect.row + index, col = field_col, width = field_width, height = 1 }
   end
   result.attachments = { row = result.body.row + body_rows + 1, col = field_col, width = field_width,
      height = attachment_rows }
   return result
end

local function position(place)
   return { relative = "editor", row = place.row, col = place.col, width = place.width, height = place.height }
end

---@param options { prepare_reply?: function, prepare_forward?: function, send?: function, activity?: function, notify?: function, choose?: function, input?: function, bounds?: fun(): { row: integer, col: integer, width: integer, height: integer }? }
function Composer.new(options)
   options = options or {}
   return setmetatable({
      prepare_reply = options.prepare_reply,
      prepare_forward = options.prepare_forward,
      send = options.send,
      activity = options.activity or function() return function() end end,
      notify = options.notify or vim.notify,
      choose = options.choose or function(...) return dialog.select(...) end,
      input = options.input or vim.ui.input,
      bounds = options.bounds,
   }, Composer)
end

function Composer:is_open()
   return self.session ~= nil
end

---The screen area of the Zenvoy window, so the form covers it exactly.
function Composer:_rect()
   local rect = self.bounds and self.bounds()
   if rect then return rect end
   local width, height = math.floor(vim.o.columns * 0.9), math.floor(vim.o.lines * 0.8)
   return {
      row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
      width = width, height = height,
   }
end

-- A horizontal frame line with optional centered text; returns the text's byte offset.
local function rule(left, right, width, text)
   local inner = width - 2
   if text and vim.api.nvim_strwidth(text) <= inner - 4 then
      local before = math.floor((inner - vim.api.nvim_strwidth(text)) / 2)
      local prefix = left .. ("─"):rep(before)
      return prefix .. text .. ("─"):rep(inner - before - vim.api.nvim_strwidth(text)) .. right, #prefix
   end
   return left .. ("─"):rep(inner) .. right
end

---Draw the frame: border, title, labels (the focused one highlighted), rules and the
---key hint, or the current status while preparing or sending.
function Composer:_draw(session)
   local frame = session.frame
   if self.session ~= session or not frame or not vim.api.nvim_buf_is_valid(frame.bufnr) then return end
   local width, focused = session.places.frame.width, fields[session.focused]
   local lines, marks = {}, {}
   local function mark(start, finish, group) marks[#marks + 1] = { #lines - 1, start, finish, group } end
   local function border(left, right, text)
      local line, start = rule(left, right, width, text)
      lines[#lines + 1] = line
      if start then
         mark(0, start, "FloatBorder")
         mark(start, start + #text, "FloatTitle")
         mark(start + #text, #line, "FloatBorder")
      else
         mark(0, #line, "FloatBorder")
      end
   end
   local function row(name)
      local label = name and labels[name] or ""
      local line = "│ " .. label .. (" "):rep(math.max(0, width - 3 - #label)) .. "│"
      lines[#lines + 1] = line
      mark(0, #"│", "FloatBorder")
      mark(#line - #"│", #line, "FloatBorder")
      if label ~= "" then mark(#"│ ", #"│ " + #label, name == focused and "ZenvoyLabel" or "ZenvoyMuted") end
   end

   border("┌", "┐", " ■ " .. session.title .. " ■ ")
   for _, name in ipairs(headers) do row(name) end
   border("├", "┤")
   for _ = 1, session.places.body.height do row() end
   border("├", "┤")
   for index = 1, session.attachment_rows do row(index == 1 and "attachments" or nil) end
   local hint = session.status and (" " .. session.status .. " ")
      or (vim.api.nvim_strwidth(HINT) <= width - 6 and HINT or SHORT_HINT)
   border("└", "┘", hint)

   vim.bo[frame.bufnr].modifiable = true
   vim.api.nvim_buf_set_lines(frame.bufnr, 0, -1, false, lines)
   vim.bo[frame.bufnr].modifiable = false
   vim.api.nvim_buf_clear_namespace(frame.bufnr, frame_namespace, 0, -1)
   for _, spec in ipairs(marks) do
      vim.api.nvim_buf_set_extmark(frame.bufnr, frame_namespace, spec[1], spec[2], { end_col = spec[3], hl_group = spec[4] })
   end
end

---Fit the frame to the Zenvoy window and place every field inside it.
function Composer:_layout(session)
   if self.session ~= session then return end
   session.places = places(self:_rect(), session.attachment_rows)
   for _, name in ipairs(fields) do
      local winid = session.fields[name].winid
      if valid_window(winid) then vim.api.nvim_win_set_config(winid, position(session.places[name])) end
   end
   if valid_window(session.frame.winid) then
      vim.api.nvim_win_set_config(session.frame.winid, position(session.places.frame))
   end
   self:_draw(session)
end

function Composer:_status(session, status)
   if self.session ~= session then return end
   session.status = status
   self:_draw(session)
end

function Composer:_focus(session, index, insert)
   if self.session ~= session then return end
   local field = session.fields[fields[index]]
   if valid_window(field.winid) then
      session.focused = index
      vim.api.nvim_set_current_win(field.winid)
      if insert and session.phase == "editing" then vim.cmd.startinsert() end
   end
end

function Composer:_resize(session)
   if self.session ~= session or not session.places then return end
   local count = 0
   for _, line in ipairs(attachment_lines(session)) do
      if line:find("%S") then count = count + 1 end
   end
   -- Keep a few body lines however many files are listed.
   local available = self:_rect().height - FIXED_ROWS - MIN_BODY_ROWS
   local rows = math.max(1, math.min(count, MAX_ATTACHMENT_ROWS, available))
   if rows == session.attachment_rows then return end
   session.attachment_rows = rows
   self:_layout(session)
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
   pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
   for _, name in ipairs(fields) do
      local field = session.fields[name]
      if field and valid_window(field.winid) then pcall(vim.api.nvim_win_close, field.winid, true) end
   end
   if session.frame and valid_window(session.frame.winid) then pcall(vim.api.nvim_win_close, session.frame.winid, true) end
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
   local ok, err = pcall(self.choose, { "Keep editing", "Discard" }, {
      prompt = "Discard this email?", title = "Discard email",
   }, function(choice)
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
      prompt = prompt, title = "Send email",
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
      self:_status(session, "Sending…")
      local function receive(send_error)
         if session.send_attempt ~= attempt or attempt.completed then return end
         attempt.completed = true
         session.phase = "editing"
         finish_activity(session)
         if send_error then
            if self.session == session then
               lock(session, false)
               self:_status(session, nil)
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
   local label = forward and "Preparing forward" or "Preparing reply"
   session.finish_activity = self.activity(label)
   self:_status(session, label .. "…")
   local function receive(err, draft)
      if self.session ~= session or session.phase ~= "preparing" then return end
      session.preparation = nil
      finish_activity(session)
      session.phase = "editing"
      lock(session, false)
      self:_status(session, nil)
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

local function scratch(filetype, editable)
   local bufnr = vim.api.nvim_create_buf(false, true)
   for option, value in pairs({
      buftype = "nofile", bufhidden = "wipe", swapfile = false, undofile = false, modifiable = editable, filetype = filetype,
   }) do
      vim.bo[bufnr][option] = value
   end
   return bufnr
end

local function open_window(bufnr, place, zindex, focusable)
   return vim.api.nvim_open_win(bufnr, false, vim.tbl_extend("force", position(place), {
      style = "minimal", border = "none", zindex = zindex, focusable = focusable,
   }))
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
   sessions = sessions + 1
   local session = {
      fields = {}, metadata = {}, focused = 1, attachment_rows = 1,
      previous_win = vim.api.nvim_get_current_win(),
      phase = options.id and "preparing" or "editing",
      title = options.forward and "Forward" or options.id and (options.all and "Reply all" or "Reply") or "New message",
      augroup = vim.api.nvim_create_augroup("ZenvoyCompose" .. sessions, { clear = true }),
   }
   self.session = session
   session.places = places(self:_rect(), session.attachment_rows)

   local frame = scratch("zenvoy-compose", false)
   session.frame = { bufnr = frame, winid = open_window(frame, session.places.frame, 70, false) }
   vim.wo[session.frame.winid].wrap = false

   for index, name in ipairs(fields) do
      local bufnr = scratch("zenvoy-compose-" .. name, session.phase == "editing")
      vim.bo[bufnr].readonly = session.phase ~= "editing"
      local winid = open_window(bufnr, session.places[name], 71, true)
      session.fields[name] = { bufnr = bufnr, winid = winid }
      vim.b[bufnr].zenvoy_compose_field = name
      -- One-line fields scroll sideways; the body wraps like prose.
      vim.wo[winid].wrap = name == "body"
      vim.wo[winid].linebreak = name == "body"
      if name == "attachments" then
         vim.wo[winid].conceallevel = 2
         vim.wo[winid].concealcursor = ""
      end
      for _, mode in ipairs({ "n", "i" }) do
         for lhs, delta in pairs({ ["<Tab>"] = 1, ["<S-Tab>"] = -1 }) do
            vim.keymap.set(mode, lhs, function()
               self:_focus(session, (index - 1 + delta) % #fields + 1, mode == "i")
            end, { buffer = bufnr, silent = true, nowait = true, desc = "Zenvoy: change compose field" })
         end
         vim.keymap.set(mode, "<C-s>", function() self:_send(session) end,
            { buffer = bufnr, silent = true, desc = "Zenvoy: send email" })
         vim.keymap.set(mode, "<C-a>", function() self:_attach(session) end,
            { buffer = bufnr, silent = true, desc = "Zenvoy: attach a file" })
      end
      for _, lhs in ipairs({ "q", "<Esc>" }) do
         vim.keymap.set("n", lhs, function()
            if self.session == session then self:request_close() end
         end, { buffer = bufnr, silent = true, nowait = true, desc = "Zenvoy: close composer" })
      end
      -- Highlight the label of the field being edited, however it was entered.
      vim.api.nvim_create_autocmd("WinEnter", {
         group = session.augroup, buffer = bufnr,
         callback = function()
            if self.session ~= session then return end
            session.focused = index
            self:_draw(session)
         end,
      })
   end
   session.baseline = field_values(session)

   -- Closing any part of the form closes all of it.
   for _, winid in ipairs(vim.tbl_map(function(name) return session.fields[name].winid end, fields)) do
      vim.api.nvim_create_autocmd("WinClosed", {
         group = session.augroup, pattern = tostring(winid), once = true,
         callback = function()
            if self.session == session then self:detach() end
         end,
      })
   end
   vim.api.nvim_create_autocmd("WinClosed", {
      group = session.augroup, pattern = tostring(session.frame.winid), once = true,
      callback = function()
         if self.session == session then self:detach() end
      end,
   })
   vim.api.nvim_create_autocmd("VimResized", {
      group = session.augroup,
      -- After the Zenvoy window itself has been resized.
      callback = function() vim.schedule(function() self:_layout(session) end) end,
   })
   vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = session.augroup, buffer = session.fields.attachments.bufnr,
      callback = function() self:_refresh(session) end,
   })
   self:_decorate(session)
   self:_draw(session)
   self:_focus(session, 1, session.phase == "editing")
   if options.id then self:_prepare(session, options) end
end

return Composer

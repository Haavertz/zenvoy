-- Actions on links and attachments in the message pane. Backend and editor operations
-- are injected so the behavior can be tested without opening real programs.
local attachments = require("zenvoy.core.attachments")
local safe_url = require("zenvoy.render.html").safe_url

local Reader = {}
Reader.__index = Reader

---@param options table
function Reader.new(options)
   return setmetatable({
      choose = options.choose or vim.ui.select,
      input = options.input or vim.ui.input,
      open = options.open or vim.ui.open,
      download = options.download,
      activity = options.activity or function() return function() end end,
      notify = options.notify or vim.notify,
      copy = options.copy,
      temporary_directory = options.temporary_directory or vim.fn.tempname,
      download_dir = options.download_dir or function() return nil end,
   }, Reader)
end

local function display(text)
   return attachments.display_name(text, "")
end

function Reader:_open(target)
   local ok, result, err = pcall(self.open, target)
   if not ok then
      self.notify("Zenvoy: unable to open " .. display(target) .. ": " .. tostring(result), vim.log.levels.ERROR)
   elseif result == nil and err then
      self.notify("Zenvoy: unable to open " .. display(target) .. ": " .. tostring(err), vim.log.levels.ERROR)
   end
end

---Open a link from the message in the default browser or mail program.
---@param url string
function Reader:open_link(url)
   local target = safe_url(url)
   if not target then
      self.notify("Zenvoy: only http, https and mailto links can be opened", vim.log.levels.WARN)
      return
   end
   self:_open(target)
end

function Reader:copy_link(url)
   local ok, err = pcall(self.copy or function(text)
      vim.fn.setreg('"', text)
      pcall(vim.fn.setreg, "+", text)
   end, url)
   if ok then
      self.notify("Zenvoy: link copied", vim.log.levels.INFO)
   else
      self.notify("Zenvoy: unable to copy link: " .. tostring(err), vim.log.levels.ERROR)
   end
end

---Show the real destination before acting on a link.
---@param url string
function Reader:link_menu(url)
   self.choose({ "Open link", "Copy link", "Cancel" }, { prompt = "Link: " .. display(url) }, function(choice)
      if choice == "Open link" then
         self:open_link(url)
      elseif choice == "Copy link" then
         self:copy_link(url)
      end
   end)
end

---@param attachment table
---@param context { id: string, mailbox?: string }
---@param directory? string
---@param callback? fun(path: string)
function Reader:_download(attachment, context, directory, callback)
   if not self.download then
      self.notify("Zenvoy: attachment downloads are not configured", vim.log.levels.ERROR)
      return
   end
   local finish = self.activity("Downloading attachment")
   local function receive(err, files)
      finish()
      local path = not err and type(files) == "table" and files[1] and files[1].path or nil
      if not path then
         self.notify("Zenvoy: " .. tostring(err or "Attachment download returned no file"), vim.log.levels.ERROR)
         return
      end
      callback(path)
   end
   local ok, err = pcall(self.download, context.id, context.mailbox, { attachment.id }, directory, receive)
   if not ok then receive(tostring(err)) end
end

---Save to the configured directory, or to Himalaya's downloads-dir.
function Reader:save(attachment, context, directory)
   self:_download(attachment, context, directory or self.download_dir(), function(path)
      self.notify("Zenvoy: saved " .. display(path), vim.log.levels.INFO)
   end)
end

function Reader:save_to(attachment, context)
   local default = self.download_dir() or vim.fs.normalize("~/Downloads")
   self.input({ prompt = "Save attachment to directory: ", default = default .. "/", completion = "dir" },
      function(answer)
         if not answer or not answer:find("%S") then return end
         local directory = vim.fs.normalize(vim.trim(answer))
         self:save(attachment, context, directory)
      end)
end

---Download into Neovim's private temporary directory and hand it to the default program.
function Reader:open_attachment(attachment, context)
   local name = display(attachment.name)
   local function run()
      self:_download(attachment, context, self.temporary_directory(), function(path)
         self:_open(path)
      end)
   end
   if attachments.is_executable(attachment.name) then
      self.choose({ "Cancel", "Open anyway" }, {
         prompt = name .. " can run code on this computer. Open it?",
      }, function(choice)
         if choice == "Open anyway" then run() end
      end)
      return
   end
   run()
end

function Reader:attachment_menu(attachment, context)
   local size = attachments.format_size(attachment.size)
   local prompt = display(attachment.name) .. (size and (" (" .. size .. ")") or "")
   self.choose({ "Open", "Save", "Save to…", "Cancel" }, { prompt = prompt }, function(choice)
      if choice == "Open" then
         self:open_attachment(attachment, context)
      elseif choice == "Save" then
         self:save(attachment, context)
      elseif choice == "Save to…" then
         self:save_to(attachment, context)
      end
   end)
end

---Pick one attachment to save when the cursor is not on one.
---@param list table[]
---@param context table
function Reader:save_any(list, context)
   if #list == 0 then
      self.notify("Zenvoy: this email has no attachments", vim.log.levels.INFO)
      return
   end
   if #list == 1 then return self:save(list[1], context) end
   local labels = {}
   for index, attachment in ipairs(list) do labels[index] = display(attachment.name) end
   labels[#labels + 1] = "All attachments"
   self.choose(labels, { prompt = "Save attachment" }, function(_, index)
      if not index then return end
      if index == #labels then
         for _, attachment in ipairs(list) do self:save(attachment, context) end
      elseif list[index] then
         self:save(list[index], context)
      end
   end)
end

return Reader

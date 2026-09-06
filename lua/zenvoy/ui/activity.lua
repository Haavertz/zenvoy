local Text = require("nui.text")
local Activity = {}
Activity.__index = Activity

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function Activity.new()
   return setmetatable({ tasks = {}, frame = 0 }, Activity)
end

function Activity:hide()
   if self.timer then
      self.timer:stop()
      self.timer:close()
      self.timer = nil
   end
   local border = self.sidebar and self.sidebar.border
   if border and border.bufnr and vim.api.nvim_buf_is_valid(border.bufnr) then
      border:set_text("bottom", nil)
   end
   self.frame = 0
end

function Activity:clear()
   self:hide()
   self.tasks, self.sidebar = {}, nil
end

function Activity:render()
   if #self.tasks == 0 then return self:hide() end
   if not self.sidebar then return end
   local winid = self.sidebar.winid
   if not winid or not vim.api.nvim_win_is_valid(winid) then return self:clear() end

   local messages = {}
   for _, task in ipairs(self.tasks) do
      for _, message in ipairs(task) do
         messages[#messages + 1] = message:gsub("%c", " ")
      end
   end
   if #messages == 0 then return self:hide() end

   local message = messages[math.floor(self.frame / #frames) % #messages + 1]
   local text = frames[self.frame % #frames + 1] .. " " .. message
   local width = math.max(0, vim.api.nvim_win_get_width(winid) - 2)
   while vim.fn.strdisplaywidth(text) > width do
      text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
   end
   self.sidebar.border:set_text("bottom", Text(" " .. text .. " ", "FloatTitle"), "center")

   if not self.timer then
      local timer = vim.uv.new_timer()
      self.timer = timer
      timer:start(100, 100, vim.schedule_wrap(function()
         if self.timer ~= timer then return end
         self.frame = self.frame + 1
         self:render()
      end))
   end
end

function Activity:attach(sidebar)
   self.sidebar = sidebar
   vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(sidebar.winid), once = true,
      callback = function() self:clear() end,
   })
   self:render()
end

---Show one or more labels; the returned callback finishes only this operation.
---@param messages string|string[]
---@return fun(): boolean
function Activity:start(messages)
   local task = type(messages) == "string" and { messages } or vim.deepcopy(messages)
   self.tasks[#self.tasks + 1] = task
   self:render()
   return function()
      for index, pending in ipairs(self.tasks) do
         if pending == task then
            table.remove(self.tasks, index)
            self:render()
            return true
         end
      end
      return false
   end
end

return Activity

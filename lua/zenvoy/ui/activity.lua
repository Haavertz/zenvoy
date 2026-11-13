local Text = require("nui.text")
local Activity = {}
Activity.__index = Activity

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function Activity.new()
   return setmetatable({ tasks = {}, frame = 0 }, Activity)
end

-- Stop the animation and give the bottom border back to its owner.
function Activity:hide()
   if self.timer then
      self.timer:stop()
      self.timer:close()
      self.timer = nil
   end
   self.frame = 0
   if not self.shown then return end
   self.shown = false
   local border = self.target and self.target.border
   if border and border.bufnr and vim.api.nvim_buf_is_valid(border.bufnr) then
      border:set_text("bottom", nil)
   end
   if self.restore then self.restore() end
end

---Stop drawing into the current window; running operations keep going.
function Activity:detach()
   self:hide()
   if self.watch then
      pcall(vim.api.nvim_del_autocmd, self.watch)
      self.watch = nil
   end
   self.target, self.restore = nil, nil
end

function Activity:clear()
   self:detach()
   self.tasks = {}
end

function Activity:render()
   if #self.tasks == 0 then return self:hide() end
   local target = self.target
   if not target then return end
   local winid = target.winid
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
   target.border:set_text("bottom", Text(" " .. text .. " ", "FloatTitle"), "center")
   self.shown = true

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

---Draw the indicator in the bottom border of `target`, the folders pane or a message
---shown over the whole window. `restore` redraws the border's own text when idle.
---@param target table NUI popup
---@param restore? fun()
function Activity:attach(target, restore)
   self:detach()
   self.target, self.restore = target, restore
   self.watch = vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(target.winid), once = true,
      callback = function()
         if self.target == target then self:clear() end
      end,
   })
   self:render()
end

---Whether the indicator currently occupies the bottom border of `target`.
---@param target table?
---@return boolean
function Activity:showing(target)
   return self.shown == true and target ~= nil and self.target == target
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

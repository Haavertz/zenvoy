local Text = require("nui.text")
local M = {}
local namespace = vim.api.nvim_create_namespace("zenvoy-message")

local function single_line(value)
   return type(value) == "string" and value:gsub("%c", " ") or ""
end

local function addresses(values)
   local result = {}
   for _, address in ipairs(values or {}) do
      local name, email = single_line(address.name), single_line(address.email)
      if name ~= "" and email ~= "" then
         result[#result + 1] = name .. " <" .. email .. ">"
      elseif name ~= "" or email ~= "" then
         result[#result + 1] = name ~= "" and name or email
      end
   end
   return #result > 0 and table.concat(result, ", ") or "—"
end

---@param popup table NUI popup
---@param message table Envelope while loading, then a normalized message.
---@param status? string Body override: empty while pending, or failure details.
function M.render(popup, message, status)
   local bufnr = popup.bufnr
   if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
   local subject = single_line(message.subject)
   if subject == "" then subject = "(no subject)" end
   local title = subject
   local width = popup.winid and vim.api.nvim_win_get_width(popup.winid) or 80
   local limit = math.max(1, width - 10)
   if vim.fn.strdisplaywidth(title) > limit then
      title = ""
      for index = 0, vim.fn.strchars(subject) - 1 do
         local char = vim.fn.strcharpart(subject, index, 1)
         if vim.fn.strdisplaywidth(title .. char .. "…") > limit then break end
         title = title .. char
      end
      title = title .. "…"
   end
   popup.border:set_text("top", Text(" ■ " .. title .. " ■ ", "FloatTitle"), "center")
   local lines = {
      "Subject: " .. subject,
      "From: " .. addresses(message.from),
      "To: " .. addresses(message.to),
      "Cc: " .. addresses(message.cc),
      "",
   }
   local body = status or message.body or ""
   if body == "" and status == nil then body = "No message content" end
   body = body:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("%z", "�")
   vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
   vim.bo[bufnr].modifiable, vim.bo[bufnr].readonly = true, false
   vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
   vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
   for row, label in ipairs({ "Subject:", "From:", "To:", "Cc:" }) do
      vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, 0, {
         end_col = #label, hl_group = "Title",
      })
   end
   vim.bo[bufnr].modifiable, vim.bo[bufnr].readonly, vim.bo[bufnr].modified = false, true, false
   if popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
      vim.api.nvim_win_set_cursor(popup.winid, { 1, 0 })
   end
end

return M

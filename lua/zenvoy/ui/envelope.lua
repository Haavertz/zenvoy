local NuiLine = require("nui.line")
local date_utils = require("zenvoy.utils.date")
local state = require("zenvoy.state")

local M = {}

local FROM_WIDTH = 23
local MIN_SUBJECT_WIDTH = 10
local FALLBACK_WINDOW_WIDTH = 80

local function has_flag(flags, target)
   target = target:lower()

   for _, flag in ipairs(flags or {}) do
      if type(flag) == "table" then
         if type(flag.iana) == "string" and flag.iana:lower() == target then
            return true
         end

         if type(flag.raw) == "string" and flag.raw:lower():find(target, 1, true) then
            return true
         end
      elseif type(flag) == "string" then
         local normalized = flag:lower()

         if normalized == target or normalized:find(target, 1, true) then
            return true
         end
      end
   end

   return false
end

local function truncate(text, width)
   if vim.fn.strdisplaywidth(text) <= width then
      return text
   end

   local ellipsis = "…"
   local available_width = math.max(0, width - vim.fn.strdisplaywidth(ellipsis))
   local truncated = ""

   for index = 0, vim.fn.strchars(text) - 1 do
      local character = vim.fn.strcharpart(text, index, 1)

      if vim.fn.strdisplaywidth(truncated .. character) > available_width then
         break
      end

      truncated = truncated .. character
   end

   return truncated .. ellipsis
end

local function fit(text, width)
   local display = truncate(text, width)
   local padding = math.max(0, width - vim.fn.strdisplaywidth(display))

   return display .. string.rep(" ", padding)
end

local function sender_name(envelope)
   if type(envelope.from) ~= "table" then
      return "Unknown"
   end

   local sender = envelope.from[1] or envelope.from

   if type(sender) ~= "table" then
      return "Unknown"
   end

   if type(sender.name) == "string" and sender.name ~= "" then
      return sender.name
   end

   if type(sender.email) == "string" and sender.email ~= "" then
      return sender.email
   end

   if type(sender.addr) == "string" and sender.addr ~= "" then
      return sender.addr
   end

   return "Unknown"
end

local function window_width(bufnr)
   local winid = vim.fn.bufwinid(bufnr)

   if winid == -1 then
      return FALLBACK_WINDOW_WIDTH
   end

   local ok, width = pcall(vim.api.nvim_win_get_width, winid)

   if not ok or type(width) ~= "number" or width <= 40 then
      return FALLBACK_WINDOW_WIDTH
   end

   return width
end

---@param bufnr integer
---@param envelopes table[]
function M.render(bufnr, envelopes)
   if not vim.api.nvim_buf_is_valid(bufnr) then
      return
   end

   envelopes = envelopes or {}
   state.envelopes = envelopes
   state.current_envelope_count = #envelopes

   vim.bo[bufnr].modifiable = true
   vim.bo[bufnr].readonly = false
   vim.bo[bufnr].filetype = "zenvoy-envelope-listing"

   if #envelopes == 0 then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].readonly = true
      vim.bo[bufnr].modified = false
      return
   end

   local date_width = date_utils.max_date_width()
   local reserved_width = 2 + 2 + (FROM_WIDTH + 1) + 1 + (date_width + 2)
   local subject_width = math.max(MIN_SUBJECT_WIDTH, window_width(bufnr) - reserved_width)

   vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

   for index, envelope in ipairs(envelopes) do
      local line = NuiLine()
      local is_seen = has_flag(envelope.flags, "seen")
      local is_flagged = has_flag(envelope.flags, "flagged")

      if is_flagged then
         line:append(" ■", "DiagnosticWarn")
      elseif not is_seen then
         line:append(" ■", "DiagnosticInfo")
      else
         line:append("  ", "Special")
      end

      local has_attachment = envelope["has-attachment"] == true or envelope.has_attachment == true
      line:append(has_attachment and "@ " or "  ", "Special")

      local subject = type(envelope.subject) == "string" and envelope.subject or "(no subject)"
      line:append(fit(subject, subject_width - 10) .. " ", "Normal")

      line:append(fit(sender_name(envelope), FROM_WIDTH) .. " ", "Identifier")
      line:append(string.rep(" ", 10))

      local relative_date = date_utils.relative_date(envelope.date)
      line:append("(" .. relative_date .. ")", "Comment")

      line:render(bufnr, -1, index)
   end

   vim.bo[bufnr].modifiable = false
   vim.bo[bufnr].readonly = true
   vim.bo[bufnr].modified = false
end

return M

local M = {}

---@class ZenvoyDraft
---@field to string Comma-separated recipients; display names are accepted.
---@field cc string
---@field bcc string
---@field subject string
---@field body string The complete editable text, including any original quotation.
---@field reply_context? { from: string, in_reply_to?: string, references?: string, id?: string, mailbox?: string }

local function header_value(value, name)
   assert(type(value) == "string", name .. " must be text")
   assert(not value:find("%c"), name .. " must be a single line without control characters")
   return value
end

local function optional_text(value)
   if value == nil then return "" end
   return value
end

-- Parse only comma-separated mailboxes, including quoted display names. Himalaya's
-- flags split on every comma, so forward bare addresses to its MIME builder.
local function recipients(value, name)
   header_value(value, name)
   if not value:find("%S") then return {} end
   local tokens, start, quoted, escaped, angle = {}, 1, false, false, false
   for index = 1, #value do
      local ch = value:sub(index, index)
      if escaped then
         escaped = false
      elseif quoted and ch == "\\" then
         escaped = true
      elseif ch == '"' then
         quoted = not quoted
      elseif not quoted then
         if ch == "<" then
            assert(not angle, "Invalid " .. name .. " address")
            angle = true
         elseif ch == ">" then
            assert(angle, "Invalid " .. name .. " address")
            angle = false
         elseif ch == "," and not angle then
            tokens[#tokens + 1] = value:sub(start, index - 1)
            start = index + 1
         end
      end
   end
   assert(not quoted and not angle, "Invalid " .. name .. " address")
   tokens[#tokens + 1] = value:sub(start)
   local result = {}
   for _, token in ipairs(tokens) do
      token = vim.trim(token)
      local address = token:match("^[^<>]*<([^<>]+)>%s*$") or token
      assert(address:match("^[^%s<>@,;\"]+@[^%s<>@,;\"]+$"), "Invalid " .. name .. " address: " .. token)
      result[#result + 1] = address
   end
   return result
end

local function context(value)
   assert(type(value) == "table", "Invalid reply context")
   assert(#recipients(value.from, "From") == 1, "Reply context needs one sender")
   for _, field in ipairs({ "in_reply_to", "references" }) do
      if value[field] ~= nil then header_value(value[field], field) end
   end
   return value
end

-- Native compose/reply produce RFC 5322 even with --json. Only inspect their
-- header block; MIME body bytes stay opaque and never need decoding here.
local function headers(raw)
   assert(type(raw) == "string", "Expected a native RFC 5322 message")
   local first, last = raw:find("\r\n\r\n", 1, true)
   local newline = "\r\n"
   if not first then first, last = raw:find("\n\n", 1, true); newline = "\n" end
   assert(first, "Missing RFC 5322 header separator")
   local block = raw:sub(1, first - 1):gsub("\r\n", "\n")
   assert(not block:find("\r", 1, true), "Invalid native message headers")
   local entries, by_name = {}, {}
   for line in (block .. "\n"):gmatch("(.-)\n") do
      if line:match("^[ \t]") then
         local entry = entries[#entries]
         assert(entry, "Header continuation has no preceding header")
         entry.value = entry.value .. " " .. vim.trim(line)
         entry.raw = entry.raw .. newline .. line
      else
         local name, value = line:match("^([%w-]+):[ \t]*(.*)$")
         assert(name, "Invalid native message header")
         name = name:lower()
         assert(not by_name[name] or (name ~= "from" and name ~= "in-reply-to" and name ~= "references"),
            "Duplicate native " .. name .. " header")
         local entry = { name = name, value = value, raw = line }
         entries[#entries + 1], by_name[name] = entry, entry
      end
   end
   return by_name, entries, newline, raw:sub(last + 1)
end

---@param draft ZenvoyDraft
---@return ZenvoyDraft? normalized
---@return string? error
function M.validate(draft)
   local ok, result = pcall(function()
      assert(type(draft) == "table", "Draft must be a table")
      local normalized, count = vim.deepcopy(draft), 0
      for _, field in ipairs({ "to", "cc", "bcc" }) do
         local addresses = recipients(optional_text(draft[field]), field)
         normalized[field] = table.concat(addresses, ", ")
         count = count + #addresses
      end
      assert(count > 0, "At least one To, Cc, or Bcc recipient is required")
      normalized.subject = header_value(optional_text(draft.subject), "Subject")
      normalized.body = optional_text(draft.body)
      assert(type(normalized.body) == "string" and not normalized.body:find("%z"), "Body must be text without NUL bytes")
      if draft.reply_context ~= nil then context(draft.reply_context) end
      return normalized
   end)
   if not ok then return nil, "Invalid draft: " .. tostring(result) end
   return result
end

---@param message ZenvoyMessage
---@param preview string Native reply RFC 5322 output, used only for identity and threading.
---@param reply_all? boolean
---@return ZenvoyDraft? draft
---@return string? error
function M.reply(message, preview, reply_all)
   local ok, result = pcall(function()
      local parsed = headers(preview)
      local reply_context = context({
         from = parsed.from and parsed.from.value,
         in_reply_to = parsed["in-reply-to"] and parsed["in-reply-to"].value,
         references = parsed.references and parsed.references.value,
      })
      local own_address = recipients(reply_context.from, "From")[1]:lower()
      local seen, to, cc = { [own_address] = true }, {}, {}
      local function append(target, addresses)
         for _, address in ipairs(addresses or {}) do
            local email = address.email
            if type(email) == "string" and email:find("%S") then
               -- A source address must remain one mailbox when converted to a form field.
               assert(#recipients(email, "source") == 1, "Invalid source address")
               local key = email:lower()
               if not seen[key] then
                  seen[key] = true
                  target[#target + 1] = email
               end
            end
         end
      end
      local primary = message.reply_to and #message.reply_to > 0 and message.reply_to or message.from
      append(to, primary)
      -- Replying to your own sent mail continues with the original recipients.
      if reply_all or #to == 0 then append(to, message.to) end
      if reply_all then append(cc, message.cc) end
      local subject = message.subject or ""
      if not subject:lower():match("^%s*re:") then subject = "Re: " .. subject end
      local body = (message.body or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n+$", "")
      if body ~= "" then body = "\n\n> " .. body:gsub("\n", "\n> ") end
      return {
         to = table.concat(to, ", "), cc = table.concat(cc, ", "), bcc = "",
         subject = subject, body = body, reply_context = reply_context,
      }
   end)
   if not ok then return nil, "Invalid Himalaya reply: " .. tostring(result) end
   return result
end

---@param raw string Native compose output with final editable headers and body.
---@param reply_context? table
---@return string? message
---@return string? error
function M.apply_context(raw, reply_context)
   local ok, result = pcall(function()
      local parsed, entries, newline, body = headers(raw)
      assert(parsed.from and #recipients(parsed.from.value, "From") == 1, "Composed message needs one sender")
      if reply_context == nil then return raw end
      context(reply_context)
      local lines = { "From: " .. reply_context.from }
      for _, entry in ipairs(entries) do
         if entry.name ~= "from" and entry.name ~= "in-reply-to" and entry.name ~= "references" then
            lines[#lines + 1] = entry.raw
         end
      end
      for _, field in ipairs({ { "in_reply_to", "In-Reply-To" }, { "references", "References" } }) do
         local value = reply_context[field[1]]
         if value and value ~= "" then lines[#lines + 1] = field[2] .. ": " .. value end
      end
      return table.concat(lines, newline) .. newline .. newline .. body
   end)
   if not ok then return nil, "Invalid Himalaya composition: " .. tostring(result) end
   return result
end

return M

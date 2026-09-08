local html = require("zenvoy.utils.html")
local M = {}

local function array(value, name)
   assert(type(value) == "table" and vim.islist(value), "expected " .. name .. " array")
   return value
end

local function addresses(value)
   assert(type(value) == "table", "invalid address header")
   local result = {}
   local function append(list)
      for _, address in ipairs(array(list, "addresses")) do
         assert(type(address) == "table", "invalid address")
         assert(address.name == nil or type(address.name) == "string", "invalid address name")
         assert(address.address == nil or type(address.address) == "string", "invalid email address")
         result[#result + 1] = { name = address.name, email = address.address }
      end
   end
   if value.List then
      append(value.List)
   else
      for _, group in ipairs(array(value.Group, "address groups")) do
         assert(type(group) == "table", "invalid address group")
         append(group.addresses)
      end
   end
   return result
end

local function body_text(parts, indices)
   local body = {}
   for _, index in ipairs(indices) do
      assert(type(index) == "number" and index >= 0 and index % 1 == 0 and index < #parts,
         "invalid body part reference")
      local part = parts[index + 1]
      assert(type(part) == "table" and type(part.body) == "table", "invalid body part")
      if part.body.Text ~= nil then
         assert(type(part.body.Text) == "string", "invalid plain text body")
         body[#body + 1] = part.body.Text
      else
         assert(type(part.body.Html) == "string", "invalid HTML body")
         body[#body + 1] = html.to_text(part.body.Html)
      end
   end
   return table.concat(body, "\n\n")
end

-- Himalaya 2.1 serializes mail-parser's MIME tree; part references are zero-based.
local function normalize(value)
   assert(type(value) == "table", "expected parsed message object")
   local parts = array(value.parts, "parts")
   assert(type(parts[1]) == "table", "missing root MIME part")
   local message = { from = {}, to = {}, cc = {}, reply_to = {}, body = "" }
   for _, header in ipairs(array(parts[1].headers, "headers")) do
      assert(type(header) == "table", "invalid header")
      -- Known HeaderName variants are strings; custom names use { other = name }.
      local name = type(header.name) == "table" and header.name.other or header.name
      assert(type(name) == "string", "invalid header name")
      local content = header.value
      name = name:lower():gsub("-", "_")
      if content ~= "Empty" and (name == "subject" or name == "from" or name == "to" or name == "cc"
         or name == "reply_to") then
         assert(type(content) == "table", "invalid " .. name .. " header")
         if name == "subject" then
            assert(type(content.Text) == "string", "invalid subject")
            message.subject = content.Text
         else
            vim.list_extend(message[name], addresses(content.Address))
         end
      end
   end

   local text_parts = array(value.text_body, "text_body")
   local html_parts = array(value.html_body, "html_body")
   message.body = body_text(parts, text_parts)
   if not message.body:find("%S") and #html_parts > 0 then
      message.body = body_text(parts, html_parts)
   end
   return message
end

---@param output string
---@return ZenvoyMessage? message
---@return string? error
function M.decode(output)
   local ok, result = pcall(function()
      return normalize(vim.json.decode(output, { luanil = { object = true } }))
   end)
   if not ok then return nil, "Invalid Himalaya JSON (message): " .. tostring(result) end
   return result
end

return M

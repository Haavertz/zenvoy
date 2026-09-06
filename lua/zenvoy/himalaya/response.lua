local M = {}

local function is_list(value)
   return type(value) == "table" and vim.islist(value)
end

local function fields_match(record, fields)
   if type(record) ~= "table" then return false end
   for name, expected in pairs(fields) do
      local value = record[name]
      if value ~= nil and type(value) ~= expected then return false end
   end
   return true
end

local function list_matches(value, predicate)
   if value == nil then return true end
   if not is_list(value) then return false end
   for _, item in ipairs(value) do
      if not predicate(item) then return false end
   end
   return true
end

local function is_address(value)
   return fields_match(value, { name = "string", email = "string" })
end

local function is_flag(value)
   return type(value) == "string" or fields_match(value, { raw = "string", iana = "string" })
end

local function is_string(value)
   return type(value) == "string"
end

local function is_mailbox(value)
   return fields_match(value, { id = "string", name = "string", total = "number", unread = "number" })
      and type(value.id) == "string"
end

local function is_envelope(value)
   return fields_match(value, {
      id = "string", subject = "string", date = "string", size = "number",
      ["message-id"] = "string", ["has-attachment"] = "boolean",
   }) and type(value.id) == "string"
      and list_matches(value.flags, is_flag)
      and list_matches(value.from, is_address)
      and list_matches(value.to, is_address)
      and list_matches(value["in-reply-to"], is_string)
end

---Validate external JSON at the boundary, preserving backend IDs and optional fields.
---JSON null object fields become nil; null array entries remain invalid records.
---@param output string
---@param collection "mailboxes"|"envelopes"
---@return table[]? records
---@return string? error
function M.decode(output, collection)
   local prefix = "Invalid Himalaya JSON (" .. collection .. "): "
   local ok, response = pcall(vim.json.decode, output, { luanil = { object = true } })
   if not ok then return nil, prefix .. tostring(response) end
   if type(response) ~= "table" or not is_list(response[collection]) then
      return nil, prefix .. "expected " .. collection .. " array"
   end

   local valid_record = collection == "mailboxes" and is_mailbox or is_envelope
   for index, record in ipairs(response[collection]) do
      if not valid_record(record) then
         return nil, prefix .. ("invalid record at index %d"):format(index)
      end
   end
   return response[collection]
end

return M

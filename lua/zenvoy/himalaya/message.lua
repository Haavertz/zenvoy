local html = require("zenvoy.utils.html")
local date = require("zenvoy.utils.date")
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

local function part_at(parts, index, kind)
   assert(type(index) == "number" and index >= 0 and index % 1 == 0 and index < #parts,
      "invalid " .. kind .. " part reference")
   return parts[index + 1]
end

-- mail-parser keeps decoded binary content in either variant.
local function binary(body)
   if type(body) ~= "table" then return nil end
   if type(body.Binary) == "table" then return body.Binary end
   if type(body.InlineBinary) == "table" then return body.InlineBinary end
end

local function attribute(attributes, name)
   if type(attributes) ~= "table" then return nil end
   for _, value in ipairs(attributes) do
      if type(value) == "table" and type(value.name) == "string" and value.name:lower() == name
         and type(value.value) == "string" then
         return value.value
      end
   end
end

local function part_metadata(part)
   local metadata = {}
   local type_name
   for _, header in ipairs(array(part.headers or {}, "part headers")) do
      if type(header) == "table" then
         local name = type(header.name) == "table" and header.name.other or header.name
         if type(name) == "string" and type(header.value) == "table" then
            name = name:lower():gsub("-", "_")
            local content_type = header.value.ContentType
            if name == "content_type" and type(content_type) == "table" then
               metadata.mime = type(content_type.c_type) == "string" and type(content_type.c_subtype) == "string"
                  and (content_type.c_type .. "/" .. content_type.c_subtype):lower() or nil
               type_name = attribute(content_type.attributes, "name") or attribute(content_type.attributes, "filename")
            elseif name == "content_disposition" and type(content_type) == "table" then
               metadata.disposition = type(content_type.c_type) == "string" and content_type.c_type:lower() or nil
               metadata.filename = attribute(content_type.attributes, "filename") or metadata.filename
            elseif name == "content_id" and type(header.value.Text) == "string" then
               metadata.cid = header.value.Text:gsub("^%s*<", ""):gsub(">%s*$", ""):lower()
            end
         end
      end
   end
   -- Content-Disposition's filename wins over Content-Type's legacy name parameter.
   metadata.filename = metadata.filename or type_name
   return metadata
end

---Stable identity for an <img src>, shared by the decoder and the HTML renderer.
---@param src string?
---@return string?
function M.image_key(src)
   if type(src) ~= "string" then return nil end
   src = vim.trim(src)
   local cid = src:match("^[cC][iI][dD]:(.+)$")
   if cid then return "cid:" .. (cid:gsub("^<", ""):gsub(">$", ""):lower()) end
   if src:match("^[hH][tT][tT][pP][sS]?://") then return "remote:" .. src end
   if src:match("^[dD][aA][tT][aA]:image/") then return "data:" .. src end
end

-- Inline images referenced from HTML. Remote images are only described here; downloading
-- them requires consent in the UI.
local function image_sources(value, parts, html_parts)
   local inline_by_cid = {}
   for _, index in ipairs(array(value.attachments or {}, "attachments")) do
      local part = part_at(parts, index, "attachment")
      if type(part) == "table" and type(part.body) == "table" then
         local metadata = part_metadata(part)
         local data = binary(part.body)
         if metadata.cid and metadata.mime and metadata.mime:match("^image/") and data then
            inline_by_cid[metadata.cid] = {
               kind = "embedded", name = metadata.filename, mime = metadata.mime,
               cid = metadata.cid, data = data,
            }
         end
      end
   end

   local result, seen, referenced = {}, {}, {}
   local function add(key, image, fallback_name)
      if not seen[key] then
         seen[key] = true
         image.name = image.name or fallback_name or "Image"
         image.key = key
         result[#result + 1] = image
      end
   end

   for _, index in ipairs(html_parts) do
      local part = parts[index + 1]
      if type(part) == "table" and type(part.body) == "table" and type(part.body.Html) == "string" then
         for _, reference in ipairs(html.image_sources(part.body.Html)) do
            local key = M.image_key(reference.src)
            if key and key:sub(1, 4) == "cid:" then
               local cid = key:sub(5)
               referenced[cid] = true
               local embedded = inline_by_cid[cid]
               if embedded then
                  add(key, vim.deepcopy(embedded), reference.name)
               end
            elseif key and key:sub(1, 7) == "remote:" then
               add(key, { kind = "remote", url = reference.src, name = reference.name or "Remote image" })
            else
               local mime, data = reference.src:match("^[dD][aA][tT][aA]:(image/[%w.+%-]+);[bB]ase64,(.+)$")
               if key and mime and data then
                  add(key, { kind = "data", mime = mime:lower(), data = data }, reference.name)
               end
            end
         end
      end
   end
   return result, referenced
end

local function body_size(body)
   if type(body) ~= "table" then return nil end
   local data = binary(body)
   if data then return #data end
   if type(body.Text) == "string" then return #body.Text end
   if type(body.Html) == "string" then return #body.Html end
end

-- Every MIME part Himalaya can download. Part IDs are the 1-based positions that
-- `himalaya attachment download` accepts.
local function attachment_list(value, parts, referenced)
   local result = {}
   for _, index in ipairs(array(value.attachments or {}, "attachments")) do
      local part = part_at(parts, index, "attachment")
      if type(part) == "table" then
         local metadata = part_metadata(part)
         local id = tostring(index + 1)
         local message_part = type(part.body) == "table" and part.body.Message ~= nil
         result[#result + 1] = {
            id = id,
            name = metadata.filename or (message_part and "message.eml") or ("attachment-" .. id),
            mime = metadata.mime or (message_part and "message/rfc822") or nil,
            size = body_size(part.body),
            inline = metadata.disposition == "inline",
            cid = metadata.cid,
            referenced = metadata.cid ~= nil and referenced[metadata.cid] == true,
         }
      end
   end
   return result
end

-- The MIME parts a client shows, in order. mail-parser also lists inline binary parts
-- (for example a photo between two text parts) in these sequences.
local function segments(parts, indices)
   local result = {}
   for _, index in ipairs(indices) do
      local part = part_at(parts, index, "body")
      assert(type(part) == "table" and type(part.body) == "table", "invalid body part")
      if part.body.Text ~= nil then
         assert(type(part.body.Text) == "string", "invalid plain text body")
         result[#result + 1] = { text = part.body.Text }
      elseif part.body.Html ~= nil then
         assert(type(part.body.Html) == "string", "invalid HTML body")
         result[#result + 1] = { html = part.body.Html }
      else
         local data = binary(part.body)
         local metadata = part_metadata(part)
         if data and metadata.mime and metadata.mime:match("^image/") then
            result[#result + 1] = { image = {
               kind = "embedded", name = metadata.filename or "Image", mime = metadata.mime,
               data = data, key = "part:" .. tostring(index + 1),
            } }
         end
      end
   end
   return result
end

---Readable text for quoting and the plain view; HTML parts are converted without markup.
---@param list table[]
---@return string
function M.plain_text(list)
   local body = {}
   for _, segment in ipairs(list or {}) do
      if segment.text then
         body[#body + 1] = segment.text
      elseif segment.html then
         body[#body + 1] = html.to_text(segment.html)
      end
   end
   return table.concat(body, "\n\n")
end

local function has_html(list)
   for _, segment in ipairs(list) do
      if segment.html then return true end
   end
   return false
end

-- Himalaya 2.x serializes mail-parser's MIME tree; part references are zero-based.
local function normalize(value)
   assert(type(value) == "table", "expected parsed message object")
   local parts = array(value.parts, "parts")
   assert(type(parts[1]) == "table", "missing root MIME part")
   local message = {
      from = {}, to = {}, cc = {}, reply_to = {}, body = "", images = {}, attachments = {},
      text_parts = {}, html_parts = {}, has_html = false,
   }
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
      elseif name == "date" and type(content) == "table" and type(content.DateTime) == "table" then
         message.date = date.parse(content.DateTime)
      end
   end

   local text_indices = array(value.text_body, "text_body")
   local html_indices = array(value.html_body, "html_body")
   message.text_parts = segments(parts, text_indices)
   message.html_parts = segments(parts, html_indices)
   message.has_html = has_html(message.html_parts)
   local referenced
   message.images, referenced = image_sources(value, parts, html_indices)
   message.attachments = attachment_list(value, parts, referenced)
   message.body = M.plain_text(message.text_parts)
   if not message.body:find("%S") and message.has_html then
      message.body = M.plain_text(message.html_parts)
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

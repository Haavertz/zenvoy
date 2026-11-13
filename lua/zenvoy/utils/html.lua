-- HTML parsing for email bodies. Nothing here executes markup or fetches resources.
local M = {}

local function set(list)
   local result = {}
   for _, value in ipairs(list) do result[value] = true end
   return result
end

local function utf8_char(code)
   if code < 0x80 then return string.char(code) end
   if code < 0x800 then return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40) end
   if code < 0x10000 then
      return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
   end
   return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
      0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end
M.utf8_char = utf8_char

local entities = {
   amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
}
-- The 96 Latin-1 names map to U+00A0–U+00FF in order (e.g. &atilde; &ccedil; &eacute;).
for index, name in ipairs({
   "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo",
   "not", "shy", "reg", "macr", "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot",
   "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest", "Agrave", "Aacute", "Acirc",
   "Atilde", "Auml", "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute",
   "Icirc", "Iuml", "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times", "Oslash",
   "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig", "agrave", "aacute", "acirc", "atilde",
   "auml", "aring", "aelig", "ccedil", "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc",
   "iuml", "eth", "ntilde", "ograve", "oacute", "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave",
   "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml",
}) do
   entities[name] = utf8_char(0xA0 + index - 1)
end
for name, code in pairs({
   OElig = 0x152, oelig = 0x153, Scaron = 0x160, scaron = 0x161, Yuml = 0x178, fnof = 0x192,
   circ = 0x2C6, tilde = 0x2DC, ensp = 0x2002, emsp = 0x2003, thinsp = 0x2009, zwnj = 0x200C,
   zwj = 0x200D, lrm = 0x200E, rlm = 0x200F, ZeroWidthSpace = 0x200B, ndash = 0x2013, mdash = 0x2014,
   lsquo = 0x2018, rsquo = 0x2019, sbquo = 0x201A, ldquo = 0x201C, rdquo = 0x201D, bdquo = 0x201E,
   dagger = 0x2020, Dagger = 0x2021, bull = 0x2022, hellip = 0x2026, permil = 0x2030, prime = 0x2032,
   Prime = 0x2033, lsaquo = 0x2039, rsaquo = 0x203A, oline = 0x203E, euro = 0x20AC, trade = 0x2122,
   larr = 0x2190, uarr = 0x2191, rarr = 0x2192, darr = 0x2193, harr = 0x2194, minus = 0x2212,
   infin = 0x221E, ne = 0x2260, le = 0x2264, ge = 0x2265, loz = 0x25CA, spades = 0x2660,
   clubs = 0x2663, hearts = 0x2665, diams = 0x2666,
}) do
   entities[name] = utf8_char(code)
end

-- Browsers also decode legacy names without the semicolon, matching the longest prefix
-- ("&copy2026" is "©2026").
local legacy = {}
for _, name in ipairs({ "amp", "lt", "gt", "quot", "AMP", "LT", "GT", "QUOT" }) do
   legacy[#legacy + 1] = name
end
for name, value in pairs(entities) do
   local code = vim.fn.char2nr(value)
   if code >= 0xA0 and code <= 0xFF then legacy[#legacy + 1] = name end
end
entities.AMP, entities.LT, entities.GT, entities.QUOT = "&", "<", ">", '"'
table.sort(legacy, function(a, b) return #a > #b end)

-- Numeric references in 0x80–0x9F mean Windows-1252 characters, as in browsers.
local windows_1252 = {
   [128] = 0x20AC, [130] = 0x201A, [131] = 0x0192, [132] = 0x201E, [133] = 0x2026, [134] = 0x2020,
   [135] = 0x2021, [136] = 0x02C6, [137] = 0x2030, [138] = 0x0160, [139] = 0x2039, [140] = 0x0152,
   [142] = 0x017D, [145] = 0x2018, [146] = 0x2019, [147] = 0x201C, [148] = 0x201D, [149] = 0x2022,
   [150] = 0x2013, [151] = 0x2014, [152] = 0x02DC, [153] = 0x2122, [154] = 0x0161, [155] = 0x203A,
   [156] = 0x0153, [158] = 0x017E, [159] = 0x0178,
}

local function numeric(code)
   code = windows_1252[code] or code
   if code > 0 and code <= 0x10FFFF and not (code >= 0xD800 and code <= 0xDFFF) then return utf8_char(code) end
end

---Decode character references in one pass, so "&amp;lt;" stays "&lt;".
---@param text string
---@return string
function M.decode_entities(text)
   if not text:find("&", 1, true) then return text end
   return (text:gsub("&(#?%w+)(;?)", function(name, semicolon)
      local hex, rest = name:match("^#[xX](%x+)(.*)$")
      local code = hex and tonumber(hex, 16)
      if not code then
         local decimal
         decimal, rest = name:match("^#(%d+)(.*)$")
         code = tonumber(decimal)
      end
      if code then
         if semicolon == ";" and rest ~= "" then return nil end
         local value = numeric(code)
         return value and (value .. rest .. (rest ~= "" and semicolon or "")) or nil
      end
      if semicolon == ";" and entities[name] then return entities[name] end
      for _, candidate in ipairs(legacy) do
         if name:sub(1, #candidate) == candidate and (semicolon == "" or #candidate < #name) then
            return entities[candidate] .. name:sub(#candidate + 1) .. semicolon
         end
      end
   end))
end
local decode_entities = M.decode_entities

local function attribute(tag, name)
   local pattern = name:gsub(".", function(char)
      return "[" .. char:lower() .. char:upper() .. "]"
   end)
   local _, quoted = tag:match(pattern .. "%s*=%s*(['\"])(.-)%1")
   if quoted then return quoted end
   return tag:match(pattern .. "%s*=%s*([^%s>]+)")
end

---Extract image references from HTML without interpreting or executing markup.
---@param source string
---@return { src: string, name?: string }[]
function M.image_sources(source)
   local result = {}
   for tag in source:gmatch("<%s*[iI][mM][gG]%f[%s/>]([^>]*)>") do
      local src = attribute(tag, "src")
      if src then
         local name = attribute(tag, "alt")
         src = vim.trim(decode_entities(src))
         if name then name = vim.trim(decode_entities(name)) end
         if src ~= "" then result[#result + 1] = { src = src, name = name } end
      end
   end
   return result
end

local void = set({
   "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input", "keygen",
   "link", "meta", "param", "source", "track", "wbr",
})
-- Content of these elements is never shown in a mail reader.
local skipped = set({
   "script", "style", "title", "template", "svg", "math", "iframe", "object", "noembed", "noframes",
   "select", "textarea", "xml",
})
-- Document wrappers are transparent: email HTML frequently omits or misplaces them.
local transparent = set({ "html", "head", "body" })
-- A start tag of these closes an open paragraph.
local closes_paragraph = set({
   "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl",
   "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header",
   "hgroup", "hr", "li", "main", "menu", "nav", "ol", "p", "pre", "section", "summary", "table", "ul",
})
local table_scope = set({ "table", "td", "th", "caption" })
local list_scope = set({ "ul", "ol", "table", "td", "th" })
local definition_scope = set({ "dl", "table", "td", "th" })
local row_scope = set({ "table" })
local cell_scope = set({ "tr", "table" })

---Parse HTML into a lenient tree of { name, attrs, children } nodes and text strings.
---Unclosed paragraphs, list items, cells and rows are closed as browsers do; stray end
---tags are ignored and never close elements outside the current table cell.
---@param source string
---@return table root
function M.parse(source)
   local root = { name = "#root", attrs = {}, children = {} }
   local stack = { root }
   local lowered
   local position, length = 1, #source

   local function current() return stack[#stack] end

   local function append_text(text)
      if text == "" then return end
      local children = current().children
      local last = children[#children]
      if type(last) == "string" then
         children[#children] = last .. text
      else
         children[#children + 1] = text
      end
   end

   local function find_open(name, boundaries)
      for index = #stack, 2, -1 do
         local open = stack[index].name
         if open == name then return index end
         if boundaries and boundaries[open] then return nil end
      end
   end

   local function pop_to(index)
      for i = #stack, index, -1 do stack[i] = nil end
   end

   local function close_open(names, boundaries)
      for index = #stack, 2, -1 do
         local open = stack[index].name
         if names[open] then
            pop_to(index)
            return
         end
         if boundaries[open] then return end
      end
   end

   local function start_tag(name, attrs, self_closing)
      if transparent[name] then return end
      if closes_paragraph[name] then
         local index = find_open("p", table_scope)
         if index then pop_to(index) end
      end
      if name == "li" then
         close_open({ li = true }, list_scope)
      elseif name == "dt" or name == "dd" then
         close_open({ dt = true, dd = true }, definition_scope)
      elseif name == "tr" then
         close_open({ tr = true }, row_scope)
      elseif name == "td" or name == "th" then
         close_open({ td = true, th = true }, cell_scope)
      elseif name == "thead" or name == "tbody" or name == "tfoot" then
         close_open({ thead = true, tbody = true, tfoot = true }, row_scope)
      elseif name == "a" then
         close_open({ a = true }, table_scope)
      end
      local node = { name = name, attrs = attrs, children = {} }
      local children = current().children
      children[#children + 1] = node
      -- XML-style self-closing is honored only for foreign tags such as Outlook's <o:p/>.
      if not void[name] and not (self_closing and name:find(":", 1, true)) then
         stack[#stack + 1] = node
      end
   end

   local function end_tag(name)
      if transparent[name] then return end
      if name == "br" then
         start_tag("br", {}, true)
         return
      end
      local boundaries
      if name == "td" or name == "th" or name == "tr" or name == "thead" or name == "tbody" or name == "tfoot"
         or name == "caption" then
         boundaries = row_scope
      elseif name == "li" then
         boundaries = { ul = true, ol = true }
      elseif name ~= "table" then
         boundaries = table_scope
      end
      local index = find_open(name, boundaries)
      if index then pop_to(index) end
   end

   while position <= length do
      local open = source:find("<", position, true)
      if not open then
         append_text(decode_entities(source:sub(position)))
         break
      end
      if open > position then append_text(decode_entities(source:sub(position, open - 1))) end
      local next_char = source:sub(open + 1, open + 1)
      if next_char == "!" then
         if source:sub(open, open + 3) == "<!--" then
            local close = source:find("-->", open + 4, true)
            position = close and close + 3 or length + 1
         elseif source:sub(open, open + 8) == "<![CDATA[" then
            local close = source:find("]]>", open + 9, true)
            append_text(source:sub(open + 9, (close or length + 1) - 1))
            position = close and close + 3 or length + 1
         else
            local close = source:find(">", open + 2, true)
            position = close and close + 1 or length + 1
         end
      elseif next_char == "?" then
         local close = source:find(">", open + 2, true)
         position = close and close + 1 or length + 1
      elseif next_char == "/" then
         local _, finish, name = source:find("^</%s*([%a][%w:%-]*)[^>]*>", open)
         if name then
            end_tag(name:lower())
            position = finish + 1
         else
            local close = source:find(">", open + 2, true)
            position = close and close + 1 or length + 1
         end
      elseif next_char:match("%a") then
         local _, name_end, name = source:find("^<([%a][%w:%-]*)", open)
         name = name:lower()
         local attrs, index, self_closing = {}, name_end + 1, false
         while true do
            local start = source:find("%S", index)
            if not start then
               index = length + 1
               break
            end
            local char = source:sub(start, start)
            if char == ">" then
               index = start + 1
               break
            elseif char == "/" then
               if source:sub(start + 1, start + 1) == ">" then
                  self_closing, index = true, start + 2
                  break
               end
               index = start + 1
            else
               local _, attribute_end, attribute_name = source:find("^([^%s/>=]+)", start)
               if not attribute_name then
                  index = start + 1
               else
                  index = attribute_end + 1
                  local value = ""
                  local _, equals_end = source:find("^%s*=%s*", index)
                  if equals_end then
                     local quote = source:sub(equals_end + 1, equals_end + 1)
                     if quote == '"' or quote == "'" then
                        local close = source:find(quote, equals_end + 2, true)
                        value = source:sub(equals_end + 2, (close or length + 1) - 1)
                        index = close and close + 1 or length + 1
                     else
                        local _, value_end, unquoted = source:find("^([^%s>]*)", equals_end + 1)
                        value, index = unquoted, value_end + 1
                     end
                  end
                  attribute_name = attribute_name:lower()
                  if attrs[attribute_name] == nil then attrs[attribute_name] = decode_entities(value) end
               end
            end
         end
         position = index
         if skipped[name] then
            if not self_closing then
               lowered = lowered or source:lower()
               local close = lowered:find("</" .. name, position, true)
               local finish = close and source:find(">", close, true)
               position = finish and finish + 1 or length + 1
            end
         else
            start_tag(name, attrs, self_closing)
         end
      else
         append_text("<")
         position = open + 1
      end
   end
   return root
end

---Parse an inline style attribute into lowercase declarations without !important.
---@param value string?
---@return table<string, string>
function M.style(value)
   local result = {}
   if type(value) ~= "string" or value == "" then return result end
   for declaration in value:gmatch("[^;]+") do
      local name, content = declaration:match("^%s*([%w%-]+)%s*:%s*(.-)%s*$")
      if name then
         result[name:lower()] = content:lower():gsub("%s*!important$", "")
      end
   end
   return result
end

---Plain text for quoting in replies and forwards: quotes use "> ", links keep their URL.
---@param html string
---@param options? { width?: integer }
---@return string
function M.to_text(html, options)
   local Document = require("zenvoy.render.document")
   local renderer = require("zenvoy.render.html")
   local document = Document.new({ quote_prefix = "> " })
   renderer.render_into(document, html, {
      width = options and options.width or 72, export = true,
   })
   return table.concat(document:finish().lines, "\n")
end

return M

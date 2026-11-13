-- Plain-text bodies are shown verbatim; quotes, signatures and URLs are only decorated.
local M = {}

local closing = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

local function count(text, char)
   return select(2, text:gsub("%" .. char, ""))
end

---Find http(s) URLs, leaving out punctuation that usually ends the sentence.
---@param line string
---@return { col: integer, end_col: integer, url: string }[]
function M.urls(line)
   local result, position = {}, 1
   while true do
      local start, finish = line:find("[hH][tT][tT][pP][sS]?://[^%s<>\"]+", position)
      if not start then break end
      local url = line:sub(start, finish)
      while #url > 0 do
         local last = url:sub(-1)
         -- A closing bracket belongs to the URL only when it balances one inside it.
         if last:match("[%.,;:!%?'\"]") or (closing[last] and count(url, last) > count(url, closing[last])) then
            url = url:sub(1, -2)
         else
            break
         end
      end
      if url:match("^[hH][tT][tT][pP][sS]?://[^/%s]") then
         result[#result + 1] = { col = start - 1, end_col = start - 1 + #url, url = url }
      end
      position = finish + 1
   end
   return result
end

---@param document table zenvoy.render.document
---@param text string
---@param options? { fold_quotes?: boolean, fold_min?: integer }
---@return table document
function M.render_into(document, text, options)
   options = options or {}
   text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("%z", "�")
   local lines = vim.split(text, "\n", { plain = true })
   while #lines > 0 and not lines[1]:find("%S") do table.remove(lines, 1) end
   while #lines > 0 and not lines[#lines]:find("%S") do lines[#lines] = nil end

   local signature, quote_start, quote_finish = false, nil, nil
   local function close_quote()
      if quote_start and options.fold_quotes and quote_finish - quote_start + 1 >= (options.fold_min or 4) then
         document:fold(quote_start, quote_finish)
      end
      quote_start = nil
   end

   for _, line in ipairs(lines) do
      local row = document:raw(line)
      if line:match("^%s*>") then
         quote_start = quote_start or row
         quote_finish = row
         document:mark(row, 0, #line, { hl = "ZenvoyQuote" })
      else
         close_quote()
         -- RFC 3676 signature separator.
         if line == "-- " then signature = true end
         if signature then document:mark(row, 0, #line, { hl = "ZenvoySignature" }) end
      end
      for _, url in ipairs(M.urls(line)) do
         document:mark(row, url.col, url.end_col, { hl = "ZenvoyLink", url = url.url })
         document:item({ kind = "link", row = row, col = url.col, end_col = url.end_col, url = url.url })
      end
   end
   close_quote()
   return document
end

return M

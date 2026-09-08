local M = {}

local entities = {
   amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
   ndash = "–", mdash = "—", hellip = "…", copy = "©", reg = "®",
   lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”", bull = "•",
}

---A text fallback for HTML mail. No markup, scripts or remote resources are executed.
---@param html string
---@return string
function M.to_text(html)
   local text = html:gsub("<!%-%-.-%-%->", "")
   for _, tag in ipairs({ "head", "script", "style" }) do
      local start, finish = text:lower():find("<" .. tag .. "%f[%s>][^>]*>.-</" .. tag .. "%s*>")
      while start do
         text = text:sub(1, start - 1) .. text:sub(finish + 1)
         start, finish = text:lower():find("<" .. tag .. "%f[%s>][^>]*>.-</" .. tag .. "%s*>")
      end
   end
   text = text:gsub("%s+", " "):gsub("<([^>]+)>", function(tag)
      local name = tag:lower():match("^%s*/?%s*([%w]+)")
      if name == "br" or name == "p" or name == "div" or name == "tr"
         or name == "li" or name == "blockquote" or name == "pre" or (name and name:match("^h[1-6]$")) then
         return "\n"
      end
      if name == "td" or name == "th" then return "\t" end
      return ""
   end)
   text = text:gsub("&(#?[%w]+);", function(entity)
      if entities[entity] then return entities[entity] end
      local code = entity:match("^#[xX](%x+)$")
      code = code and tonumber(code, 16) or tonumber(entity:match("^#(%d+)$"))
      if code and code > 0 and code <= 0x10FFFF and not (code >= 0xD800 and code <= 0xDFFF) then
         return vim.fn.nr2char(code)
      end
      return "&" .. entity .. ";"
   end)
   return vim.trim(text:gsub(" *\n *", "\n"):gsub("\n\n\n+", "\n\n"))
end

return M

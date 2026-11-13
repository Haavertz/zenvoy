-- Lay out parsed email HTML as readable text, similar to a webmail view.
-- Rendering never fetches anything: images become markers that the UI can resolve.
local html = require("zenvoy.utils.html")
local Document = require("zenvoy.render.document")

local M = {}
local strwidth = vim.api.nvim_strwidth

local function set(list)
   local result = {}
   for _, value in ipairs(list) do result[value] = true end
   return result
end

-- Blocks separated from their neighbors by a blank line.
local spaced_blocks = set({ "p", "ul", "ol", "dl", "blockquote", "pre", "table", "hr", "figure", "fieldset",
   "address", "h1", "h2", "h3", "h4", "h5", "h6" })
-- Blocks that only start on a new line.
local line_blocks = set({ "div", "li", "tr", "td", "th", "dt", "dd", "center", "section", "article", "header",
   "footer", "main", "nav", "aside", "figcaption", "caption", "details", "summary", "tbody", "thead", "tfoot",
   "form", "hgroup", "menu", "dir", "dialog", "legend", "option", "optgroup", "body", "html" })
local headings = set({ "h1", "h2", "h3", "h4", "h5", "h6" })
local bold_tags = set({ "b", "strong", "th" })
local italic_tags = set({ "i", "em", "cite", "dfn", "var" })
local underline_tags = set({ "u", "ins" })
local strike_tags = set({ "s", "strike", "del" })
local code_tags = set({ "code", "kbd", "samp", "tt" })
-- Cells containing these cannot be laid out as a one-line grid cell.
local complex_content = set({ "table", "ul", "ol", "dl", "blockquote", "pre", "hr", "h1", "h2", "h3", "h4", "h5",
   "h6", "li" })
local bullets = { "•", "◦", "▪" }

local function style_of(node)
   if node.style == nil then node.style = html.style(node.attrs.style) end
   return node.style
end

local function hidden(node)
   if node.attrs.hidden ~= nil then return true end
   local style = style_of(node)
   if style.display == "none" or style.visibility == "hidden" then return true end
   local opacity = style.opacity and tonumber(style.opacity:match("^[%d.]+"))
   if opacity == 0 then return true end
   local max_height = style["max-height"]
   -- Common preheader trick: max-height:0 with overflow:hidden.
   return max_height ~= nil and max_height:match("^0") ~= nil and not max_height:match("^0%.%d*[1-9]")
      and style.overflow == "hidden"
end

local function bold_weight(value)
   if not value then return false end
   if value == "bold" or value == "bolder" then return true end
   local number = tonumber(value)
   return number ~= nil and number >= 600
end

local function tiny(value)
   if value == nil then return false end
   local number = tonumber(tostring(value):match("^%s*(%d+%.?%d*)%s*p?x?%s*$"))
   return number ~= nil and number <= 3
end

---Only links that a reader may open: http, https and mailto.
---@param href string?
---@return string?
function M.safe_url(href)
   if type(href) ~= "string" then return nil end
   href = href:gsub("[%c%s]", "")
   local scheme = href:match("^(%a[%w+.%-]*):")
   if not scheme then return nil end
   scheme = scheme:lower()
   if scheme == "http" or scheme == "https" then
      return #href > #scheme + 3 and href or nil
   elseif scheme == "mailto" then
      return #href > 7 and href or nil
   end
end

local function merge(list, additions)
   local result = {}
   for _, value in ipairs(list or {}) do result[#result + 1] = value end
   for _, value in ipairs(additions) do
      if not vim.tbl_contains(result, value) then result[#result + 1] = value end
   end
   return result
end

local function derive(parent, fields)
   return setmetatable(fields, { __index = parent })
end

local Renderer = {}
Renderer.__index = Renderer

---@param document table zenvoy.render.document
---@param options { width?: integer, export?: boolean, resolve_image?: fun(src: string): table?, fold_quotes?: boolean, fold_min?: integer }
function Renderer.new(document, options)
   return setmetatable({ doc = document, options = options, runs = {} }, Renderer)
end

function Renderer:width()
   return self.options.width or math.huge
end

function Renderer:flush(ctx)
   local runs = self.runs
   if #runs == 0 then return end
   self.runs = {}
   local meaningful = false
   for _, run in ipairs(runs) do
      if run.br or run.image or run.atomic or (run.text and Document.clean(run.text):find("%S")) then
         meaningful = true
         break
      end
   end
   if not meaningful then return end
   local base = self.doc:bars(ctx.quote) .. ctx.indent
   local first, rest = base, base
   if ctx.li and not ctx.li.used then
      first = self.doc:bars(ctx.quote) .. ctx.li.base .. ctx.li.marker
      ctx.li.used = true
   end
   local quoted = ctx.quote > 0 and "ZenvoyQuote" or nil
   if ctx.pre then
      self.doc:preformatted(runs, { prefix = base, line_hl = quoted, level = ctx.quote })
   else
      self.doc:paragraph(runs, {
         width = self:width(), first_prefix = first, rest_prefix = rest, line_hl = quoted, level = ctx.quote,
      })
   end
end

function Renderer:text(text, ctx)
   if text == "" then return end
   self.runs[#self.runs + 1] = { text = text, hl = ctx.hl, link = ctx.link, group = ctx.group }
end

function Renderer:children(node, ctx)
   for _, child in ipairs(node.children) do
      if type(child) == "string" then
         self:text(child, ctx)
      else
         self:element(child, ctx)
      end
   end
end

---Inline formatting from the tag and its style attribute.
function Renderer:styled(node, ctx)
   local name, style = node.name, style_of(node)
   local additions = {}
   local decoration = style["text-decoration"] or style["text-decoration-line"] or ""
   if bold_tags[name] or headings[name] or bold_weight(style["font-weight"]) then
      additions[#additions + 1] = "ZenvoyBold"
   end
   if italic_tags[name] or style["font-style"] == "italic" then additions[#additions + 1] = "ZenvoyItalic" end
   if underline_tags[name] or decoration:find("underline", 1, true) then
      additions[#additions + 1] = "ZenvoyUnderline"
   end
   if strike_tags[name] or decoration:find("line-through", 1, true) then additions[#additions + 1] = "ZenvoyStrike" end
   if code_tags[name] then additions[#additions + 1] = "ZenvoyCode" end
   if headings[name] then additions[#additions + 1] = "ZenvoyHeading" end
   local link = name == "a" and M.safe_url(node.attrs.href) or nil
   if link then additions[#additions + 1] = "ZenvoyLink" end
   if #additions == 0 then return ctx end
   local fields = { hl = merge(ctx.hl, additions) }
   if link then fields.link, fields.group = link, {} end
   return derive(ctx, fields)
end

function Renderer:image(node, ctx)
   local attrs, style = node.attrs, style_of(node)
   if tiny(attrs.width) or tiny(attrs.height) or tiny(style.width) or tiny(style.height) then return end
   local alt = vim.trim(Document.clean((attrs.alt or ""):gsub("%c", " ")))
   if alt == "" and attrs.title then alt = vim.trim(Document.clean(attrs.title:gsub("%c", " "))) end
   local label
   if self.options.export then
      if alt == "" then return end
      label = "[Image: " .. alt .. "]"
   else
      local image = self.options.resolve_image and attrs.src and self.options.resolve_image(attrs.src) or nil
      if alt == "" and not image then return end
      local name = alt ~= "" and alt or (image and image.name ~= "Image" and image.name) or nil
      label = name and ("[Image: " .. name:gsub("%c", " ") .. "]") or "[Image]"
      self:text(" ", ctx)
      self.runs[#self.runs + 1] = {
         text = label, atomic = true, hl = merge(ctx.hl, { "ZenvoyImage" }), image = image, link = ctx.link,
         group = ctx.group or {},
      }
      self:text(" ", ctx)
      return
   end
   self:text(" ", ctx)
   self.runs[#self.runs + 1] = { text = label, atomic = true }
   self:text(" ", ctx)
end

function Renderer:list(node, ctx)
   self:flush(ctx)
   local depth = (ctx.list and ctx.list.depth or 0) + 1
   if ctx.li and not ctx.li.used then ctx.li.used = true end
   local fields = {
      li = false,
      list = { ordered = node.name == "ol", counter = (tonumber(node.attrs.start) or 1) - 1, depth = depth },
   }
   if depth == 1 then
      fields.indent = ctx.indent .. "  "
      self.doc:blank()
   end
   local child = derive(ctx, fields)
   self:children(node, child)
   self:flush(child)
   if depth == 1 then self.doc:blank() end
end

function Renderer:list_item(node, ctx)
   self:flush(ctx)
   local list, marker = ctx.list, nil
   if list and list.ordered then
      list.counter = list.counter + 1
      marker = list.counter .. ". "
   elseif self.options.export then
      marker = "- "
   else
      local depth = list and list.depth or 1
      marker = bullets[(depth - 1) % #bullets + 1] .. " "
   end
   local child = derive(self:styled(node, ctx), {
      li = { marker = marker, used = false, base = ctx.indent },
      indent = ctx.indent .. string.rep(" ", strwidth(marker)),
   })
   self:children(node, child)
   self:flush(child)
end

function Renderer:blockquote(node, ctx)
   self:flush(ctx)
   self.doc:blank()
   local child = derive(self:styled(node, ctx), { quote = ctx.quote + 1, li = false })
   local start = self.doc:next_row()
   self:children(node, child)
   self:flush(child)
   local finish = self.doc:next_row() - 1
   local lines = self.doc.lines
   while start <= finish and not lines[start + 1]:find("%S") do start = start + 1 end
   if ctx.quote == 0 and self.options.fold_quotes and finish - start + 1 >= (self.options.fold_min or 4) then
      self.doc:fold(start, finish)
   end
   self.doc:blank()
end

local function cells_of(row)
   local cells = {}
   for _, child in ipairs(row.children) do
      if type(child) == "table" and (child.name == "td" or child.name == "th") then
         cells[#cells + 1] = child
      elseif type(child) == "table" or (type(child) == "string" and child:find("%S")) then
         return nil
      end
   end
   return cells
end

local function table_rows(node)
   local rows = {}
   local function add_rows(parent, header)
      for _, child in ipairs(parent.children) do
         if type(child) == "table" then
            if child.name == "tr" then
               if not hidden(child) then
                  local cells = cells_of(child)
                  if not cells then return false end
                  local all_headers = #cells > 0
                  for _, cell in ipairs(cells) do
                     if cell.name ~= "th" then all_headers = false end
                  end
                  rows[#rows + 1] = { cells = cells, header = header or all_headers }
               end
            elseif child.name == "thead" or child.name == "tbody" or child.name == "tfoot" then
               if add_rows(child, child.name == "thead") == false then return false end
            elseif child.name ~= "colgroup" and child.name ~= "col" then
               return false
            end
         elseif child:find("%S") then
            return false
         end
      end
   end
   if add_rows(node, false) == false then return nil end
   return rows
end

local function simple(node)
   for _, child in ipairs(node.children) do
      if type(child) == "table" then
         if complex_content[child.name] or not simple(child) then return false end
      end
   end
   return true
end

---Lay out a data table as aligned columns when every cell fits on one line.
function Renderer:grid(node, ctx)
   if self:width() == math.huge or ctx.pre then return false end
   local rows = table_rows(node)
   if not rows or #rows == 0 then return false end
   local columns = 0
   for _, row in ipairs(rows) do
      for _, cell in ipairs(row.cells) do
         if (tonumber(cell.attrs.colspan) or 1) > 1 or (tonumber(cell.attrs.rowspan) or 1) > 1
            or hidden(cell) or not simple(cell) then
            return false
         end
      end
      columns = math.max(columns, #row.cells)
   end
   if columns < 2 then return false end

   local rendered, widths = {}, {}
   for index = 1, columns do widths[index] = 0 end
   local base = derive(ctx, { quote = 0, indent = "", li = false })
   for row_index, row in ipairs(rows) do
      rendered[row_index] = {}
      for column, cell in ipairs(row.cells) do
         local fragment = Document.new({ quote_prefix = self.doc.quote_prefix })
         local renderer = Renderer.new(fragment, vim.tbl_extend("force", self.options, {
            width = math.huge, fold_quotes = false,
         }))
         local cell_ctx = renderer:styled(cell, base)
         renderer:children(cell, cell_ctx)
         renderer:flush(cell_ctx)
         fragment:finish()
         if #fragment.lines > 1 then return false end
         rendered[row_index][column] = fragment
         widths[column] = math.max(widths[column], strwidth(fragment.lines[1] or ""))
      end
   end
   local used = {}
   for column = 1, columns do
      if widths[column] > 0 then used[#used + 1] = column end
   end
   if #used < 2 then return false end
   local prefix = self.doc:bars(ctx.quote) .. ctx.indent
   local total = strwidth(prefix)
   for index, column in ipairs(used) do total = total + widths[column] + (index > 1 and 2 or 0) end
   if total > self:width() then return false end

   local quoted = ctx.quote > 0 and "ZenvoyQuote" or nil
   for row_index, row in ipairs(rows) do
      local parts, offsets, length, has_text = { prefix }, {}, #prefix, false
      for index, column in ipairs(used) do
         local fragment = rendered[row_index][column]
         local text = fragment and fragment.lines[1] or ""
         if text ~= "" then has_text = true end
         offsets[column] = length
         if index < #used then text = text .. string.rep(" ", widths[column] - strwidth(text) + 2) end
         parts[#parts + 1] = text
         length = length + #text
      end
      if has_text then
         local line = (table.concat(parts):gsub("%s+$", ""))
         local target = self.doc:push(line, ctx.quote)
         if quoted then self.doc:mark(target, 0, #line, { hl = quoted }) end
         for _, column in ipairs(used) do
            local fragment = rendered[row_index][column]
            if fragment then
               local offset = offsets[column]
               for _, mark in ipairs(fragment.marks) do
                  self.doc:mark(target, mark.col + offset, mark.end_col + offset, { hl = mark.hl, url = mark.url })
               end
               for _, item in ipairs(fragment.items) do
                  self.doc:item(vim.tbl_extend("force", {}, item, {
                     row = target, col = item.col + offset, end_col = item.end_col + offset,
                  }))
               end
            end
         end
         if row.header and row_index < #rows then
            self.doc:rule(total, {
               prefix = prefix, level = ctx.quote, char = self.options.export and "-" or "─",
            })
         end
      end
   end
   return true
end

function Renderer:table(node, ctx)
   self:flush(ctx)
   self.doc:blank()
   if not self:grid(node, ctx) then
      self:children(node, self:styled(node, ctx))
      self:flush(ctx)
   end
   self.doc:blank()
end

function Renderer:element(node, ctx)
   local name = node.name
   if hidden(node) then return end
   if name == "br" then
      self.runs[#self.runs + 1] = { br = true }
      return
   elseif name == "img" then
      local block = style_of(node).display == "block"
      if block then self:flush(ctx) end
      self:image(node, ctx)
      if block then self:flush(ctx) end
      return
   elseif name == "hr" then
      self:flush(ctx)
      self.doc:blank()
      local width = self:width()
      self.doc:rule(width == math.huge and 72 or width, {
         prefix = self.doc:bars(ctx.quote) .. ctx.indent, level = ctx.quote,
         char = self.options.export and "-" or "─",
      })
      self.doc:blank()
      return
   elseif name == "table" then
      return self:table(node, ctx)
   elseif name == "ul" or name == "ol" then
      return self:list(node, ctx)
   elseif name == "li" then
      return self:list_item(node, ctx)
   elseif name == "blockquote" then
      return self:blockquote(node, ctx)
   end

   local child = self:styled(node, ctx)
   if name == "pre" then child = derive(child, { pre = true, hl = merge(child.hl, { "ZenvoyCode" }) }) end
   local display = style_of(node).display
   if spaced_blocks[name] then
      self:flush(ctx)
      self.doc:blank()
      self:children(node, child)
      self:flush(child)
      self.doc:blank()
   elseif line_blocks[name] or display == "block" or display == "table" or display == "list-item" then
      self:flush(ctx)
      self:children(node, child)
      self:flush(child)
   elseif name == "a" and child.link and self.options.export then
      local start = #self.runs + 1
      self:children(node, child)
      local text = {}
      for index = start, #self.runs do text[#text + 1] = self.runs[index].text or "" end
      text = vim.trim(Document.clean(table.concat(text)))
      local target = child.link:gsub("^[mM][aA][iI][lL][tT][oO]:", "")
      if text ~= "" and text ~= child.link and text ~= target then
         self.runs[#self.runs + 1] = { text = " <" .. target .. ">" }
      end
   else
      self:children(node, child)
   end
end

---Render one HTML document into a Document.
---@param document table zenvoy.render.document
---@param source string
---@param options? { width?: integer, export?: boolean, resolve_image?: fun(src: string): table?, fold_quotes?: boolean, fold_min?: integer }
---@return table document
function M.render_into(document, source, options)
   local renderer = Renderer.new(document, options or {})
   local ctx = { quote = 0, indent = "", hl = {}, li = false }
   renderer:children(html.parse(source), ctx)
   renderer:flush(ctx)
   return document
end

return M

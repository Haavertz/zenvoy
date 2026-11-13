-- A width-aware text document with highlight marks, interactive items and folds.
-- Rows and columns are 0-based byte positions, ready for extmarks.
local Document = {}
Document.__index = Document

local strwidth = vim.api.nvim_strwidth

-- Invisible characters used for spacing tricks in marketing mail and preheaders.
local function clean(text)
   return (text:gsub("\194\160", " ") -- NBSP
      :gsub("\226\128[\139-\143]", "") -- U+200B–U+200F
      :gsub("\226\129\160", "") -- U+2060
      :gsub("\239\187\191", "") -- U+FEFF
      :gsub("\205\143", "") -- U+034F
      :gsub("\194\173", "")) -- soft hyphen
end
Document.clean = clean

---@class ZenvoyRun
---@field text? string
---@field hl? string[] Highlight groups combined on this text.
---@field link? string
---@field image? table
---@field group? table Identity shared by all runs of one anchor or image.
---@field br? boolean Hard line break.
---@field atomic? boolean Never wrap inside this run.

local function style_key(run)
   if not run then return nil end
   if run.key == nil then
      run.key = table.concat(run.hl or {}, ",") .. "|" .. (run.link or "")
   end
   return run.key
end

local function styled(run)
   return run and (run.link or run.image or (run.hl and #run.hl > 0))
end

local function same_style(a, b)
   if a == b then return true end
   if not a or not b or a.image or b.image then return false end
   return style_key(a) == style_key(b) and a.group == b.group
end

---@param options? { quote_prefix?: string }
function Document.new(options)
   options = options or {}
   return setmetatable({
      lines = {}, marks = {}, items = {}, folds = {},
      quote_prefix = options.quote_prefix or "│ ",
      pending_blank = false,
      last_blank = true, -- Never start with a blank line.
      last_level = 0,
   }, Document)
end

---@return integer row 0-based index of the next line.
function Document:next_row()
   return #self.lines
end

function Document:bars(level)
   return string.rep(self.quote_prefix, level or 0)
end

---Ask for one blank line before the next content. Repeated requests collapse.
function Document:blank()
   self.pending_blank = true
end

local function rtrim(text)
   return (text:gsub("%s+$", ""))
end

---@param text? string
---@param level? integer Quote depth, used to draw quote bars on separating blank lines.
---@param blank? boolean A collapsible empty line.
---@return integer? row
function Document:push(text, level, blank)
   level = level or 0
   if blank then
      self.pending_blank = false
      if self.last_blank then return nil end
      self.lines[#self.lines + 1] = rtrim(self:bars(level))
      self.last_blank, self.last_level = true, level
      return #self.lines - 1
   end
   if self.pending_blank and not self.last_blank then
      self.lines[#self.lines + 1] = rtrim(self:bars(math.min(level, self.last_level)))
   end
   self.pending_blank = false
   self.lines[#self.lines + 1] = text
   self.last_blank, self.last_level = false, level
   return #self.lines - 1
end

---Append a line verbatim; empty lines are kept (plain text and preformatted blocks).
---@return integer row
function Document:raw(text, level)
   if text:find("%S") then return self:push(text, level) end
   if self.pending_blank and not self.last_blank then
      self.lines[#self.lines + 1] = rtrim(self:bars(math.min(level or 0, self.last_level)))
   end
   self.pending_blank = false
   self.lines[#self.lines + 1] = text
   self.last_blank, self.last_level = true, level or 0
   return #self.lines - 1
end

---@param row integer
---@param col integer
---@param end_col integer
---@param spec { hl?: string, url?: string }
function Document:mark(row, col, end_col, spec)
   if not row or end_col <= col then return end
   self.marks[#self.marks + 1] = { row = row, col = col, end_col = end_col, hl = spec.hl, url = spec.url }
end

---@param item table { kind: "link"|"image"|"attachment", row, col, end_col, ... }
function Document:item(item)
   self.items[#self.items + 1] = item
end

function Document:fold(start_row, end_row)
   if start_row and end_row and end_row > start_row then
      self.folds[#self.folds + 1] = { start = start_row, finish = end_row }
   end
end

---A horizontal rule filling the width after the prefix.
function Document:rule(width, options)
   options = options or {}
   local prefix = options.prefix or ""
   local count = math.max(3, (width or 40) - strwidth(prefix))
   local row = self:push(prefix .. string.rep(options.char or "─", count), options.level)
   self:mark(row, #prefix, #self.lines[row + 1], { hl = options.hl or "ZenvoySeparator" })
   return row
end

local function tokenize(runs)
   local words, word = {}, nil
   local function add(text, run)
      if text == "" then return end
      if not word then
         word = { segments = {}, width = 0 }
         words[#words + 1] = word
      end
      local last = word.segments[#word.segments]
      if last and last.run == run then
         last.text = last.text .. text
      else
         word.segments[#word.segments + 1] = { text = text, run = run }
      end
      word.width = word.width + strwidth(text)
   end
   local function space()
      word = nil
      local last = words[#words]
      if last and not last.space then words[#words + 1] = { space = true } end
   end
   for _, run in ipairs(runs) do
      if run.br then
         word = nil
         words[#words + 1] = { br = true }
      elseif run.atomic then
         add(run.text or "", run)
      else
         local text, position = clean(run.text or ""), 1
         while position <= #text do
            local start, finish = text:find("%s+", position)
            if start == position then
               space()
               position = finish + 1
            else
               add(text:sub(position, (start or #text + 1) - 1), run)
               position = start or #text + 1
            end
         end
      end
   end
   return words
end

local function fill(words, width, first_prefix, rest_prefix)
   local lines = {}
   local line, pending_space
   local function start(prefix)
      line = { prefix = prefix, pieces = {}, width = strwidth(prefix), has_word = false }
      pending_space = false
   end
   start(first_prefix)
   for _, word in ipairs(words) do
      if word.space then
         pending_space = line.has_word
      elseif word.br then
         lines[#lines + 1] = line
         start(rest_prefix)
      else
         local needed = word.width + (pending_space and 1 or 0)
         if line.has_word and line.width + needed > width then
            lines[#lines + 1] = line
            start(rest_prefix)
         end
         if pending_space then
            line.pieces[#line.pieces + 1] = { space = true }
            line.width = line.width + 1
         end
         for _, segment in ipairs(word.segments) do
            line.pieces[#line.pieces + 1] = { text = segment.text, run = segment.run }
         end
         line.width = line.width + word.width
         line.has_word, pending_space = true, false
      end
   end
   if line.has_word then lines[#lines + 1] = line end
   return lines
end

local function same_link(a, b)
   return a ~= nil and b ~= nil and a.link ~= nil and not a.image and not b.image
      and a.link == b.link and a.group == b.group
end

function Document:_emit(line, options)
   local level = options.level or 0
   if not line.has_word then return self:push(nil, level, true) end
   local parts, styles, links, images, col = { line.prefix }, {}, {}, {}, #line.prefix
   local function extend(spans, run, finish, same)
      local last = spans[#spans]
      if last and last.end_col == col and same(last.run, run) then
         last.end_col = finish
      else
         spans[#spans + 1] = { col = col, end_col = finish, run = run }
      end
   end
   for index, piece in ipairs(line.pieces) do
      local text, run, link_run = piece.text, piece.run, piece.run
      if piece.space then
         text = " "
         local before, after = line.pieces[index - 1], line.pieces[index + 1]
         before, after = before and before.run, after and after.run
         run = styled(before) and same_style(before, after) and before or nil
         link_run = same_link(before, after) and before or nil
      end
      parts[#parts + 1] = text
      local finish = col + #text
      if styled(run) and run.hl and #run.hl > 0 then extend(styles, run, finish, same_style) end
      if run and run.image then
         images[#images + 1] = { col = col, end_col = finish, run = run }
      elseif link_run and link_run.link then
         extend(links, link_run, finish, same_link)
      end
      col = finish
   end
   local text = table.concat(parts)
   local row = self:push(text, level)
   if options.line_hl then self:mark(row, 0, #text, { hl = options.line_hl }) end
   if options.prefix_hl then self:mark(row, 0, #line.prefix, { hl = options.prefix_hl }) end
   for _, span in ipairs(styles) do
      for _, group in ipairs(span.run.hl) do self:mark(row, span.col, span.end_col, { hl = group }) end
   end
   for _, span in ipairs(links) do
      -- One mark over the whole anchor keeps the underline continuous across styled words.
      self:mark(row, span.col, span.end_col, { hl = "ZenvoyLink", url = span.run.link })
      self:item({ kind = "link", row = row, col = span.col, end_col = span.end_col, url = span.run.link,
         group = span.run.group })
   end
   for _, span in ipairs(images) do
      local run = span.run
      if run.link then self:mark(row, span.col, span.end_col, { url = run.link }) end
      self:item({ kind = "image", row = row, col = span.col, end_col = span.end_col, image = run.image,
         url = run.link, group = run.group })
   end
   return row
end

---Wrap inline runs into lines.
---@param runs ZenvoyRun[]
---@param options { width?: integer, first_prefix?: string, rest_prefix?: string, prefix_hl?: string, line_hl?: string, level?: integer }
---@return integer? first_row
---@return integer? last_row
function Document:paragraph(runs, options)
   options = options or {}
   local first_prefix = options.first_prefix or ""
   local rest_prefix = options.rest_prefix or first_prefix
   local lines = fill(tokenize(runs), options.width or math.huge, first_prefix, rest_prefix)
   local first, last
   for _, line in ipairs(lines) do
      local row = self:_emit(line, options)
      if row then
         first = first or row
         last = row
      end
   end
   return first, last
end

---Preformatted text: spaces and line breaks are kept; tabs become four spaces.
---@param runs ZenvoyRun[]
---@param options { prefix?: string, prefix_hl?: string, line_hl?: string, level?: integer }
---@return integer? first_row
---@return integer? last_row
function Document:preformatted(runs, options)
   options = options or {}
   local prefix = options.prefix or ""
   local lines, line = {}, { prefix = prefix, pieces = {}, has_word = true }
   for _, run in ipairs(runs) do
      if run.br then
         lines[#lines + 1] = line
         line = { prefix = prefix, pieces = {}, has_word = true }
      else
         local text = (run.text or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "    ")
         local position = 1
         while true do
            local newline = text:find("\n", position, true)
            local chunk = text:sub(position, (newline or #text + 1) - 1)
            if chunk ~= "" then line.pieces[#line.pieces + 1] = { text = chunk, run = run } end
            if not newline then break end
            lines[#lines + 1] = line
            line = { prefix = prefix, pieces = {}, has_word = true }
            position = newline + 1
         end
      end
   end
   lines[#lines + 1] = line
   local function empty(candidate)
      for _, piece in ipairs(candidate.pieces) do
         if piece.text:find("%S") then return false end
      end
      return true
   end
   while #lines > 0 and empty(lines[1]) do table.remove(lines, 1) end
   while #lines > 0 and empty(lines[#lines]) do table.remove(lines) end
   local first, last
   for _, candidate in ipairs(lines) do
      local row
      if empty(candidate) then
         row = self:raw(rtrim(prefix), options.level)
      else
         row = self:_emit(candidate, options)
      end
      first = first or row
      last = row
   end
   return first, last
end

---Drop trailing blank lines and anything that pointed at them.
---@return table self
function Document:finish()
   while #self.lines > 0 and not self.lines[#self.lines]:find("[^%s│>]") do
      self.lines[#self.lines] = nil
   end
   local count = #self.lines
   local function keep(list, field)
      local result = {}
      for _, value in ipairs(list) do
         if value[field] < count then result[#result + 1] = value end
      end
      return result
   end
   self.marks = keep(self.marks, "row")
   self.items = keep(self.items, "row")
   local folds = {}
   for _, fold in ipairs(self.folds) do
      if fold.start < count then
         fold.finish = math.min(fold.finish, count - 1)
         if fold.finish > fold.start then folds[#folds + 1] = fold end
      end
   end
   self.folds = folds
   return self
end

return Document

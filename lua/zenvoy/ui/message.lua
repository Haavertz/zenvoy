local Text = require("nui.text")
local Document = require("zenvoy.render.document")
local html_renderer = require("zenvoy.render.html")
local plain_renderer = require("zenvoy.render.plain")
local attachments = require("zenvoy.core.attachments")
local date = require("zenvoy.utils.date")
local decoder = require("zenvoy.himalaya.message")

local M = {}
local namespace = vim.api.nvim_create_namespace("zenvoy-message")
local LABEL_WIDTH = 10
local strwidth = vim.api.nvim_strwidth

---@class ZenvoyView
---@field items table[] Links, images and attachments sorted by position (0-based rows).
---@field mode "html"|"plain"
---@field has_html boolean
---@field folds table[]

local function single_line(value)
   return type(value) == "string" and value:gsub("%c", " ") or ""
end

local function address_list(values)
   if type(values) ~= "table" then return {} end
   if values.email or values.name or values.addr or values.address then return { values } end
   return values
end

local function address_runs(values)
   local runs = {}
   for _, address in ipairs(address_list(values)) do
      if type(address) == "table" then
         local name = vim.trim(single_line(address.name))
         local email = vim.trim(single_line(address.email or address.addr or address.address))
         if name ~= "" or email ~= "" then
            if #runs > 0 then runs[#runs + 1] = { text = ", " } end
            if name ~= "" and email ~= "" and name ~= email then
               runs[#runs + 1] = { text = name }
               runs[#runs + 1] = { text = " " }
               runs[#runs + 1] = { text = "<" .. email .. ">", hl = { "ZenvoyMuted" }, atomic = true }
            else
               runs[#runs + 1] = { text = name ~= "" and name or email, atomic = name == "" }
            end
         end
      end
   end
   return runs
end

local function same_addresses(a, b)
   local function key(values)
      local list = {}
      for _, address in ipairs(address_list(values)) do
         if type(address) == "table" and type(address.email) == "string" then list[#list + 1] = address.email:lower() end
      end
      table.sort(list)
      return table.concat(list, ",")
   end
   return key(a) == key(b)
end

local function header(document, label, runs, width, options)
   options = options or {}
   if #runs == 0 then
      if not options.placeholder then return end
      runs = { { text = options.placeholder, hl = { "ZenvoyMuted" } } }
   end
   local prefix = label .. string.rep(" ", math.max(1, LABEL_WIDTH - #label))
   local first = document:paragraph(runs, {
      width = width, first_prefix = prefix, rest_prefix = string.rep(" ", LABEL_WIDTH),
   })
   if first then document:mark(first, 0, #label, { hl = "ZenvoyLabel" }) end
end

-- Columns of the pane's text area.
local function pane_width(winid)
   local width = 81
   if winid and vim.api.nvim_win_is_valid(winid) then
      local info = vim.fn.getwininfo(winid)[1]
      width = vim.api.nvim_win_get_width(winid) - (info and info.textoff or 0)
   end
   return math.max(21, width)
end

local function text_width(winid, max_width)
   local width = pane_width(winid) - 1
   if type(max_width) == "number" and max_width > 0 then width = math.min(width, max_width) end
   return math.max(20, width)
end

local function set_title(popup, subject)
   local width = popup.winid and vim.api.nvim_win_is_valid(popup.winid) and vim.api.nvim_win_get_width(popup.winid)
      or 80
   local limit = math.max(1, width - 10)
   local title = subject
   if vim.fn.strdisplaywidth(title) > limit then
      title = ""
      for index = 0, vim.fn.strchars(subject) - 1 do
         local char = vim.fn.strcharpart(subject, index, 1)
         if vim.fn.strdisplaywidth(title .. char .. "…") > limit then break end
         title = title .. char
      end
      title = title .. "…"
   end
   popup.border:set_text("top", Text(" ■ " .. title .. " ■ ", "FloatTitle"), "center")
end

local function image_line(document, image, label)
   local text = label or ("[Image: " .. single_line(image.name or "Image") .. "]")
   local row = document:push(text)
   document:mark(row, 0, #text, { hl = "ZenvoyImage" })
   document:item({ kind = "image", row = row, col = 0, end_col = #text, image = image })
end

local function render_body(document, message, mode, options)
   local start = document:next_row()
   local parts = mode == "html" and message.html_parts or message.text_parts
   local lookup = {}
   for _, image in ipairs(message.images or {}) do
      if image.key then lookup[image.key] = image end
   end
   local html_options = {
      width = options.width, fold_quotes = options.fold_quotes,
      resolve_image = function(src)
         local key = decoder.image_key(src)
         return key and lookup[key] or nil
      end,
   }
   local plain_options = { fold_quotes = options.fold_quotes }
   if type(parts) == "table" and #parts > 0 then
      for _, part in ipairs(parts) do
         document:blank()
         if part.html then
            if mode == "html" then
               html_renderer.render_into(document, part.html, html_options)
            else
               plain_renderer.render_into(document, decoder.plain_text({ part }), plain_options)
            end
         elseif part.text then
            plain_renderer.render_into(document, part.text, plain_options)
         elseif part.image then
            image_line(document, part.image)
         end
      end
   elseif type(message.body) == "string" then
      plain_renderer.render_into(document, message.body, plain_options)
   end
   -- In the plain view, images referenced by the HTML alternative stay reachable as markers.
   if mode == "plain" and type(message.images) == "table" and #message.images > 0 then
      document:blank()
      for index, image in ipairs(message.images) do
         local name = single_line(image.name)
         if name == "" then name = "Image" end
         image_line(document, image, ("[Image %d: %s]  Press I to render"):format(index, name))
      end
   end
   if document:next_row() == start then
      document:blank()
      document:push("No message content")
   end
end

local function render_attachments(document, message, width, rule_width)
   local listed = {}
   for _, attachment in ipairs(message.attachments or {}) do
      -- Inline images placed by the HTML body are shown where they appear.
      if not attachment.referenced then listed[#listed + 1] = attachment end
   end
   if #listed == 0 then return end
   document:blank()
   document:rule(rule_width)
   local title = ("%d attachment%s"):format(#listed, #listed == 1 and "" or "s")
   local title_row = document:push(title)
   document:mark(title_row, 0, #title, { hl = "ZenvoyLabel" })
   local names, name_width = {}, 0
   for index, attachment in ipairs(listed) do
      names[index] = attachments.display_name(attachment.name, "attachment-" .. tostring(attachment.id))
      name_width = math.max(name_width, strwidth(names[index]))
   end
   name_width = math.min(name_width, 40)
   for index, attachment in ipairs(listed) do
      local name = names[index]
      local size = attachments.format_size(attachment.size)
      local details = attachments.kind(attachment.name, attachment.mime) .. (size and (" · " .. size) or "")
      local padding = string.rep(" ", math.max(2, name_width - strwidth(name) + 2))
      local line = "  " .. name .. padding .. details
      local row = document:push(line)
      document:mark(row, 2, 2 + #name, { hl = "ZenvoyAttachment" })
      document:mark(row, 2 + #name + #padding, #line, { hl = "ZenvoyMuted" })
      document:item({ kind = "attachment", row = row, col = 2, end_col = 2 + #name, attachment = attachment })
   end
end

local function paint(popup, document)
   local bufnr, winid = popup.bufnr, popup.winid
   vim.bo[bufnr].modifiable, vim.bo[bufnr].readonly = true, false
   vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, document.lines)
   vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
   for _, mark in ipairs(document.marks) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, mark.row, mark.col, {
         end_row = mark.row, end_col = mark.end_col, hl_group = mark.hl, url = mark.url,
      })
   end
   vim.bo[bufnr].modifiable, vim.bo[bufnr].readonly, vim.bo[bufnr].modified = false, true, false
   if winid and vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_call(winid, function()
         if vim.wo.foldmethod ~= "manual" then return end
         vim.cmd("silent! normal! zE")
         for _, fold in ipairs(document.folds) do
            vim.cmd(("silent! %d,%dfold"):format(fold.start + 1, fold.finish + 1))
         end
      end)
      vim.api.nvim_win_set_cursor(winid, { 1, 0 })
   end
end

---Fold label for collapsed quotations.
---@return string
function M.foldtext()
   local count = vim.v.foldend - vim.v.foldstart + 1
   return ("  ··· %d quoted line%s (Enter to expand)"):format(count, count == 1 and "" or "s")
end

---@param popup table NUI popup
---@param message table Envelope while loading, then a normalized message.
---@param status? string Body override: empty while pending, or failure details.
---@param options? { mode?: "html"|"plain", max_width?: integer, fold_quotes?: boolean }
---@return ZenvoyView view
function M.render(popup, message, status, options)
   options = options or {}
   local view = { items = {}, folds = {}, mode = "plain", has_html = message.has_html == true }
   local bufnr = popup.bufnr
   if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return view end
   local subject = vim.trim(single_line(message.subject))
   if subject == "" then subject = "(no subject)" end
   set_title(popup, subject)

   local width = text_width(popup.winid, options.max_width)
   -- The separators between header, body and attachments span the whole pane.
   local rule_width = pane_width(popup.winid)
   local document = Document.new()
   header(document, "From:", address_runs(message.from), width, { placeholder = "—" })
   header(document, "To:", address_runs(message.to), width, { placeholder = "—" })
   header(document, "Cc:", address_runs(message.cc), width)
   if message.reply_to and not same_addresses(message.reply_to, message.from) then
      header(document, "Reply-To:", address_runs(message.reply_to), width)
   end
   local epoch = type(message.date) == "number" and message.date or date.parse(message.date)
   if epoch then
      header(document, "Date:", {
         { text = date.format(epoch) }, { text = " " },
         { text = "(" .. date.relative(epoch) .. ")", hl = { "ZenvoyMuted" }, atomic = true },
      }, width)
   end
   header(document, "Subject:", { { text = subject, hl = { "ZenvoySubject" } } }, width)
   document:rule(rule_width)
   document:blank()

   if status ~= nil then
      if status ~= "" then plain_renderer.render_into(document, status) end
   else
      view.mode = (options.mode ~= "plain" and view.has_html) and "html" or "plain"
      render_body(document, message, view.mode, {
         width = width, fold_quotes = options.fold_quotes ~= false,
      })
      render_attachments(document, message, width, rule_width)
   end
   document:finish()
   paint(popup, document)
   table.sort(document.items, function(a, b)
      if a.row ~= b.row then return a.row < b.row end
      return a.col < b.col
   end)
   view.items, view.folds = document.items, document.folds
   return view
end

---The item under a cursor. Attachments and images also match anywhere on their row.
---@param view ZenvoyView?
---@param row integer 1-based cursor row
---@param col integer 0-based byte column
---@return table?
function M.item_at(view, row, col)
   local fallback
   for _, item in ipairs(view and view.items or {}) do
      if item.row == row - 1 then
         if col >= item.col and col < item.end_col then return item end
         if not fallback and item.kind ~= "link" then fallback = item end
      end
   end
   return fallback
end

---Next or previous navigable item; continuation pieces of one link are skipped.
---@param view ZenvoyView?
---@param row integer 1-based cursor row
---@param col integer 0-based byte column
---@param backward? boolean
---@return table?
function M.adjacent_item(view, row, col, backward)
   local stops, previous = {}, nil
   for _, item in ipairs(view and view.items or {}) do
      if not (item.group and previous and previous.group == item.group) then stops[#stops + 1] = item end
      previous = item
   end
   if #stops == 0 then return nil end
   local cursor_row = row - 1
   if backward then
      for index = #stops, 1, -1 do
         local item = stops[index]
         if item.row < cursor_row or (item.row == cursor_row and item.end_col <= col) then return item end
      end
      return stops[#stops]
   end
   for _, item in ipairs(stops) do
      if item.row > cursor_row or (item.row == cursor_row and item.col > col) then return item end
   end
   return stops[1]
end

---Show context for the item under the cursor in the bottom border, like a browser status bar.
---@param popup table
---@param item table?
function M.status(popup, item)
   local border = popup and popup.border
   if not border then return end
   local text
   if item and item.kind == "link" then
      text = "→ " .. single_line(item.url)
   elseif item and item.kind == "image" then
      text = item.url and ("I show image · gx → " .. single_line(item.url)) or "I or Enter show image"
   elseif item and item.kind == "attachment" then
      text = "Enter open/save · S save"
   end
   if not text then
      -- Safe while unmounted: NUI keeps the text for the next mount.
      pcall(border.set_text, border, "bottom", nil)
      return
   end
   if not border.bufnr or not vim.api.nvim_buf_is_valid(border.bufnr) then return end
   local width = popup.winid and vim.api.nvim_win_is_valid(popup.winid) and vim.api.nvim_win_get_width(popup.winid)
      or 80
   local limit = math.max(10, width - 6)
   if strwidth(text) > limit then
      text = vim.fn.strcharpart(text, 0, limit - 1)
      while strwidth(text) > limit - 1 do text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1) end
      text = text .. "…"
   end
   border:set_text("bottom", Text(" " .. text .. " ", "ZenvoyMuted"), "left")
end

return M

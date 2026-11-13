-- A small dialog in the middle of the editor for confirmations and short menus.
-- `select` takes the same arguments as vim.ui.select, so callers keep a plain
-- `choose(items, options, callback)` dependency that tests can replace.
local Popup = require("nui.popup")
local Text = require("nui.text")
local attachments = require("zenvoy.core.attachments")
local highlights = require("zenvoy.ui.highlights")
local BORDER = require("zenvoy.ui.layout").BORDER

local M = {}

local namespace = vim.api.nvim_create_namespace("zenvoy-dialog")
local MIN_WIDTH, MAX_WIDTH = 30, 64
local MAX_BUTTONS = 4
local GAP = "   "
local PADDING = { top = 1, bottom = 1, left = 2, right = 2 }
local active

local function cells(text)
   return vim.api.nvim_strwidth(text)
end

-- Prompts quote names and links from email: drop control and reordering characters.
local function clean(text)
   text = attachments.strip_format_controls(tostring(text or ""))
   return (text:gsub("\r\n?", "\n"):gsub("\t", " "):gsub("[%z\1-\8\11-\31\127]", ""))
end

-- Longest prefix that fits in `limit` cells, never empty for non-empty text.
local function head(text, limit)
   local starts, used, stop = vim.str_utf_pos(text), 0, 0
   for index, start in ipairs(starts) do
      local finish = (starts[index + 1] or #text + 1) - 1
      local width = cells(text:sub(start, finish))
      if stop > 0 and used + width > limit then break end
      used, stop = used + width, finish
   end
   return text:sub(1, stop)
end

-- Longest suffix that fits in `limit` cells.
local function tail(text, limit)
   local starts, used, start = vim.str_utf_pos(text), 0, #text + 1
   for index = #starts, 1, -1 do
      local width = cells(text:sub(starts[index], start - 1))
      if used + width > limit then break end
      used, start = used + width, starts[index]
   end
   return text:sub(start)
end

-- Keep both ends of long labels so a file extension stays visible.
local function shorten(text, limit)
   if cells(text) <= limit then return text end
   local left = math.ceil((limit - 1) / 2)
   return head(text, left) .. "…" .. tail(text, limit - 1 - cells(head(text, left)))
end

local function wrap(text, limit)
   local lines = {}
   for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
      local line = ""
      for word in paragraph:gmatch("%S+") do
         if line ~= "" and cells(line) + 1 + cells(word) <= limit then
            line = line .. " " .. word
         else
            if line ~= "" then lines[#lines + 1] = line end
            -- Split words wider than the dialog, such as long links, instead of hiding them.
            while cells(word) > limit do
               local piece = head(word, limit)
               lines[#lines + 1] = piece
               word = word:sub(#piece + 1)
            end
            line = word
         end
      end
      lines[#lines + 1] = line
   end
   while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
   return lines
end

local function center(text, width)
   return string.rep(" ", math.max(0, math.floor((width - cells(text)) / 2))) .. text
end

---Compute the text, size and item positions of a dialog.
local function build(prompt, labels, kind)
   local max_width = math.max(10, math.min(MAX_WIDTH, vim.o.columns - 10))
   local row_width = 0
   for index, label in ipairs(labels) do
      row_width = row_width + cells(label) + 4 + (index > 1 and #GAP or 0)
   end
   local list = kind == "list" or #labels > MAX_BUTTONS or row_width > max_width

   local content = list and 0 or row_width
   if list then
      for _, label in ipairs(labels) do content = math.max(content, cells(label) + 2) end
   end
   for _, paragraph in ipairs(vim.split(prompt, "\n", { plain = true })) do
      content = math.max(content, cells(paragraph))
   end
   local width = math.min(max_width, math.max(MIN_WIDTH, content))

   local lines = wrap(prompt, width)
   local max_height = math.max(3, vim.o.lines - vim.o.cmdheight - 8)
   local item_rows = list and #labels or 1
   -- The choices must stay visible: shorten very long prompts, such as tracking links.
   local room = math.max(1, max_height - math.min(item_rows, max_height - 2) - 1)
   if #lines > room then
      while #lines > room do lines[#lines] = nil end
      lines[#lines] = head(lines[#lines], width - 1) .. "…"
   end
   if #lines == 1 then lines[1] = center(lines[1], width) end
   if #lines > 0 then lines[#lines + 1] = "" end

   local spec = { lines = lines, width = width, list = list, items = {} }
   if list then
      for index, label in ipairs(labels) do
         spec.items[index] = { row = #lines + index - 1, label = shorten(label, width - 2) }
      end
   else
      local row = {}
      for index, label in ipairs(labels) do row[index] = "[ " .. label .. " ]" end
      local text = center(table.concat(row, GAP), width)
      local col = #text:match("^ *")
      for index, button in ipairs(row) do
         spec.items[index] = { row = #lines, col = col, end_col = col + #button }
         col = col + #button + #GAP
      end
      spec.row_text = text
   end
   spec.height = math.min(max_height, #lines + item_rows)
   return spec
end

local function render(dialog)
   local spec, bufnr = dialog.spec, dialog.popup.bufnr
   local lines = vim.deepcopy(spec.lines)
   if spec.list then
      for index, item in ipairs(spec.items) do
         lines[#lines + 1] = (index == dialog.focus and "› " or "  ") .. item.label
      end
   else
      lines[#lines + 1] = spec.row_text
   end
   vim.bo[bufnr].modifiable = true
   vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
   vim.bo[bufnr].modifiable = false

   vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
   for index, item in ipairs(spec.items) do
      local focused = index == dialog.focus
      if spec.list then
         if focused then
            vim.api.nvim_buf_set_extmark(bufnr, namespace, item.row, 0, {
               end_row = item.row + 1, hl_group = "ZenvoyButtonActive", hl_eol = true,
            })
         end
      else
         vim.api.nvim_buf_set_extmark(bufnr, namespace, item.row, item.col, {
            end_col = item.end_col, hl_group = focused and "ZenvoyButtonActive" or "ZenvoyButton",
         })
      end
   end
end

local function place_cursor(dialog)
   local winid = dialog.popup.winid
   if not winid or not vim.api.nvim_win_is_valid(winid) then return end
   local item = dialog.spec.items[dialog.focus]
   local target = { item.row + 1, dialog.spec.list and 0 or item.col + 2 }
   local cursor = vim.api.nvim_win_get_cursor(winid)
   if cursor[1] ~= target[1] or cursor[2] ~= target[2] then vim.api.nvim_win_set_cursor(winid, target) end
end

local function finish(dialog, index)
   if dialog.done then return end
   dialog.done = true
   if active == dialog then active = nil end
   local was_current = vim.api.nvim_get_current_win() == dialog.popup.winid
   dialog.popup:unmount()
   if was_current and vim.api.nvim_win_is_valid(dialog.previous_win) then
      vim.api.nvim_set_current_win(dialog.previous_win)
   end
   if index then
      dialog.on_choice(dialog.items[index], index)
   else
      dialog.on_choice(nil, nil)
   end
end

local function move(dialog, delta)
   dialog.focus = (dialog.focus - 1 + delta) % #dialog.items + 1
   render(dialog)
   place_cursor(dialog)
end

---Ask for one of `items` in a centered dialog. Choices are buttons on one row, or a
---list when they do not fit (or `options.kind == "list"`). Focus starts on the first
---item, so callers list the safe choice first. Escape, `q` and leaving the window cancel.
---@param items any[]
---@param options? { prompt?: string, title?: string, kind?: string, format_item?: fun(item: any): string }
---@param on_choice fun(item: any?, index: integer?)
function M.select(items, options, on_choice)
   assert(type(items) == "table", "items must be a list")
   assert(type(on_choice) == "function", "on_choice must be a function")
   options = options or {}
   -- One dialog at a time; a cancelled dialog's callback may itself open another.
   while active do finish(active, nil) end
   if #items == 0 then
      on_choice(nil, nil)
      return
   end
   highlights.setup()

   local labels = {}
   for index, item in ipairs(items) do
      local label = options.format_item and options.format_item(item) or item
      labels[index] = vim.trim((clean(label):gsub("\n", " ")))
   end
   local spec = build(vim.trim(clean(options.prompt)), labels, options.kind)
   local title = vim.trim((clean(options.title or "Zenvoy"):gsub("\n", " ")))

   local dialog = {
      items = items, on_choice = on_choice, spec = spec, focus = 1,
      previous_win = vim.api.nvim_get_current_win(),
   }
   dialog.popup = Popup({
      relative = "editor", position = "50%", enter = true, focusable = true, zindex = 200,
      size = { width = spec.width, height = spec.height },
      border = {
         style = BORDER,
         padding = PADDING,
         text = { top = Text(" ■ " .. title .. " ■ ", "FloatTitle"), top_align = "center" },
      },
      buf_options = {
         buftype = "nofile", bufhidden = "wipe", swapfile = false, undofile = false,
         modifiable = false, filetype = "zenvoy-dialog",
      },
      win_options = {
         wrap = false, cursorline = false, number = false, relativenumber = false,
         signcolumn = "no", foldcolumn = "0", list = false,
      },
   })
   active = dialog
   vim.cmd.stopinsert()
   dialog.popup:mount()
   render(dialog)
   place_cursor(dialog)

   local bufnr = dialog.popup.bufnr
   local function map(keys, callback)
      for _, lhs in ipairs(keys) do
         vim.keymap.set("n", lhs, callback, { buffer = bufnr, nowait = true, silent = true, desc = "Zenvoy: dialog" })
      end
   end
   local backward = spec.list and { "k", "<Up>", "<S-Tab>" } or { "h", "<Left>", "<S-Tab>" }
   local forward = spec.list and { "j", "<Down>", "<Tab>" } or { "l", "<Right>", "<Tab>" }
   map(backward, function() move(dialog, -1) end)
   map(forward, function() move(dialog, 1) end)
   map({ "<CR>" }, function() finish(dialog, dialog.focus) end)
   map({ "<Esc>", "q", "<C-c>" }, function() finish(dialog, nil) end)

   -- Other motions must not leave the focused choice, and the dialog stays read-only.
   vim.api.nvim_create_autocmd("CursorMoved", { buffer = bufnr, callback = function() place_cursor(dialog) end })
   vim.api.nvim_create_autocmd("InsertEnter", { buffer = bufnr, callback = function() vim.cmd.stopinsert() end })
   -- Leaving or closing the window cancels; windows cannot be closed inside these events.
   vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
      buffer = bufnr,
      callback = function() vim.schedule(function() finish(dialog, nil) end) end,
   })
   vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(dialog.popup.winid), once = true,
      callback = function() vim.schedule(function() finish(dialog, nil) end) end,
   })
end

---Cancel the open dialog, if any.
function M.close()
   if active then finish(active, nil) end
end

return M

-- The keybindings help opened with `?`. Keys come from the configured keymaps, so
-- remapped keys show as configured and disabled ones are left out.
local Popup = require("nui.popup")
local Text = require("nui.text")
local keymaps = require("zenvoy.keymaps")
local highlights = require("zenvoy.ui.highlights")
local BORDER = require("zenvoy.ui.layout").BORDER

local M = {}

local namespace = vim.api.nvim_create_namespace("zenvoy-help")
local PADDING = { top = 1, bottom = 1, left = 2, right = 2 }
local GAP = 4
local active

-- Rows name a configurable `action`, or fixed `keys` (Vim's own and the composer's).
local SECTIONS = {
   emails = {
      title = "Emails",
      rows = {
         { keys = { "j", "k" }, text = "move" },
         { action = "enter", text = "open" },
         { action = "next_page", text = "next page" },
         { action = "previous_page", text = "previous page" },
         { action = "compose", text = "compose" },
         { action = "reply", text = "reply" },
         { action = "reply_all", text = "reply all" },
         { action = "forward", text = "forward" },
         { action = "focus_sidebar", text = "folders" },
         { action = "close_or_back", text = "back / close" },
         { action = "help", text = "keybindings" },
      },
   },
   reading = {
      title = "Reading",
      rows = {
         { action = "toggle_fullscreen", text = "full screen on/off" },
         { action = "next_item", text = "next link or file" },
         { action = "previous_item", text = "previous link or file" },
         { action = "enter", text = "open link/file/quote" },
         { action = "open_link", text = "open link" },
         { action = "save_attachment", text = "save attachment" },
         { action = "toggle_view", text = "HTML / plain text" },
         { action = "show_image", text = "show image" },
      },
   },
   writing = {
      title = "Writing",
      rows = {
         { keys = { "<Tab>", "<S-Tab>" }, text = "next / previous field" },
         { keys = { "<C-a>" }, text = "attach file" },
         { keys = { "<C-s>" }, text = "send" },
         { keys = { "<Esc>", "q" }, text = "close" },
      },
   },
}

local function cells(text)
   return vim.api.nvim_strwidth(text)
end

-- `<Tab>` reads as Tab and `<CR>` as Enter, like the composer's hints.
local function display(lhs)
   local name = lhs:match("^<([^<>]+)>$")
   if not name then return lhs end
   local upper = name:upper()
   if upper == "CR" or upper == "ENTER" or upper == "RETURN" then return "Enter" end
   return name
end

---One section with a row per action that has keys.
local function section(spec, mappings)
   local rows = {}
   for _, row in ipairs(spec.rows) do
      local keys = row.keys or keymaps.keys_for(mappings, row.action)
      if #keys > 0 then
         local labels = {}
         for index, lhs in ipairs(keys) do labels[index] = display(lhs) end
         rows[#rows + 1] = { key = table.concat(labels, "/"), text = row.text }
      end
   end
   return { title = spec.title, rows = rows }
end

---Lines of stacked sections, each with its keys aligned; each line is
---`{ text, marks = { { col, end_col, hl } } }`.
local function column(sections)
   local lines = {}
   for _, part in ipairs(sections) do
      if #part.rows > 0 then
         local key_width = 0
         for _, row in ipairs(part.rows) do key_width = math.max(key_width, cells(row.key)) end
         if #lines > 0 then lines[#lines + 1] = { text = "", marks = {} } end
         lines[#lines + 1] = { text = part.title, marks = { { 0, #part.title, "ZenvoyHeading" } } }
         for _, row in ipairs(part.rows) do
            local text = "  " .. row.key .. string.rep(" ", key_width - cells(row.key) + 2) .. row.text
            lines[#lines + 1] = { text = text, marks = { { 2, 2 + #row.key, "ZenvoyKey" } } }
         end
      end
   end
   return lines
end

local function width_of(lines)
   local width = 0
   for _, line in ipairs(lines) do width = math.max(width, cells(line.text)) end
   return width
end

-- Two columns side by side.
local function join(left, right)
   local left_width = width_of(left)
   local lines = {}
   for index = 1, math.max(#left, #right) do
      local first, second = left[index] or { text = "", marks = {} }, right[index]
      local line = { text = first.text, marks = vim.deepcopy(first.marks) }
      if second and second.text ~= "" then
         line.text = line.text .. string.rep(" ", left_width - cells(first.text) + GAP)
         local offset = #line.text
         line.text = line.text .. second.text
         for _, mark in ipairs(second.marks) do
            line.marks[#line.marks + 1] = { mark[1] + offset, mark[2] + offset, mark[3] }
         end
      end
      lines[index] = line
   end
   return lines
end

---Build the help text: two columns when the editor is wide enough, otherwise one.
---@param mappings table<string, string|false>
---@param max_width integer
---@return table[] lines
function M.lines(mappings, max_width)
   local emails = section(SECTIONS.emails, mappings)
   local reading = section(SECTIONS.reading, mappings)
   local writing = section(SECTIONS.writing, mappings)
   local lines = join(column({ emails }), column({ reading, writing }))
   if width_of(lines) > max_width then lines = column({ emails, reading, writing }) end
   return lines
end

---Close the help, if open, and return to the window it was opened from.
function M.close()
   local help = active
   if not help then return end
   active = nil
   local was_current = vim.api.nvim_get_current_win() == help.popup.winid
   help.popup:unmount()
   if was_current and vim.api.nvim_win_is_valid(help.previous_win) then
      vim.api.nvim_set_current_win(help.previous_win)
   end
end

---@param mappings table<string, string|false> The configured keymaps.
function M.open(mappings)
   M.close()
   highlights.setup()
   local max_width = math.max(20, vim.o.columns - 2 - PADDING.left - PADDING.right - 4)
   local max_height = math.max(3, vim.o.lines - vim.o.cmdheight - 2 - PADDING.top - PADDING.bottom - 2)
   local lines = M.lines(mappings, max_width)
   local width = math.min(max_width, width_of(lines))
   -- Taller than the editor: the window scrolls with the usual motions.
   local height = math.min(max_height, #lines)

   local popup = Popup({
      relative = "editor", position = "50%", enter = true, focusable = true, zindex = 150,
      size = { width = width, height = height },
      border = {
         style = BORDER,
         padding = PADDING,
         text = {
            top = Text(" ■ Keybindings ■ ", "FloatTitle"), top_align = "center",
            bottom = Text(" q close ", "FloatTitle"), bottom_align = "center",
         },
      },
      buf_options = {
         buftype = "nofile", bufhidden = "wipe", swapfile = false, undofile = false,
         modifiable = false, filetype = "zenvoy-help",
      },
      win_options = {
         wrap = false, cursorline = false, number = false, relativenumber = false,
         signcolumn = "no", foldcolumn = "0", list = false,
      },
   })
   local help = { popup = popup, previous_win = vim.api.nvim_get_current_win() }
   active = help
   popup:mount()

   local bufnr = popup.bufnr
   local text = {}
   for index, line in ipairs(lines) do text[index] = line.text end
   vim.bo[bufnr].modifiable = true
   vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, text)
   vim.bo[bufnr].modifiable = false
   for index, line in ipairs(lines) do
      for _, mark in ipairs(line.marks) do
         vim.api.nvim_buf_set_extmark(bufnr, namespace, index - 1, mark[1], { end_col = mark[2], hl_group = mark[3] })
      end
   end

   local function close()
      if active == help then M.close() end
   end
   for _, lhs in ipairs({ "q", "<Esc>", "?", "<CR>" }) do
      vim.keymap.set("n", lhs, close, { buffer = bufnr, nowait = true, silent = true, desc = "Zenvoy: close help" })
   end
   -- Leaving or closing the window also closes the help; windows cannot close inside these events.
   vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
      buffer = bufnr,
      callback = function() vim.schedule(close) end,
   })
   vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(popup.winid), once = true,
      callback = function() vim.schedule(close) end,
   })
end

---@return boolean
function M.is_open()
   return active ~= nil
end

return M

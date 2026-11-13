vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local config = require("zenvoy.config")
local help = require("zenvoy.ui.help")

vim.o.columns, vim.o.lines = 120, 40

local function flush() vim.wait(20, function() return false end, 5) end

local function texts(lines)
   local result = {}
   for index, line in ipairs(lines) do result[index] = line.text end
   return result
end

-- The help window as shown: its buffer, window and lines.
local function shown()
   for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "zenvoy-help" then
         local winid = vim.fn.bufwinid(bufnr)
         return { bufnr = bufnr, winid = winid, lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) }
      end
   end
end

local function press(lhs)
   for _, map in ipairs(vim.api.nvim_buf_get_keymap(assert(shown()).bufnr, "n")) do
      if map.lhs == lhs then return map.callback() end
   end
   error("missing help mapping " .. lhs)
end

t.test("every default key is listed in two columns: emails, then reading and writing", function()
   config.setup()
   t.equal({
      "Emails                    Reading",
      "  j/k    move               z      full screen on/off",
      "  Enter  open               Tab    next link or file",
      "  n      next page          S-Tab  previous link or file",
      "  N      previous page      Enter  open link/file/quote",
      "  c      compose            gx     open link",
      "  r      reply              S      save attachment",
      "  R      reply all          T      HTML / plain text",
      "  f      forward            I      show image",
      "  s      folders",
      "  q      back / close     Writing",
      "  ?      keybindings        Tab/S-Tab  next / previous field",
      "                            C-a        attach file",
      "                            C-s        send",
      "                            Esc/q      close",
   }, texts(help.lines(config.get().keymaps, 100)))
end)

t.test("the help fits an 80x24 editor without scrolling", function()
   config.setup()
   vim.o.columns, vim.o.lines = 80, 24
   help.open(config.get().keymaps)
   local view = assert(shown())
   t.equal(#view.lines, vim.api.nvim_win_get_height(view.winid))
   assert(view.lines[1]:find("Reading", 1, true), view.lines[1])
   help.close()
   vim.o.columns, vim.o.lines = 120, 40
end)

t.test("remapped keys are shown as configured and disabled ones are left out", function()
   config.setup({ keymaps = { s = false, gs = "focus_sidebar", z = false, ["<leader>v"] = "toggle_fullscreen" } })
   local text = table.concat(texts(help.lines(config.get().keymaps, 100)), "\n")
   assert(text:find("  gs     folders", 1, true), text)
   assert(not text:find("  s      folders", 1, true), text)
   assert(text:find("<leader>v  full screen on/off", 1, true), text)
   assert(not text:find("  z ", 1, true), text)
   config.setup()
end)

t.test("a narrow editor stacks the sections in one column", function()
   config.setup()
   local lines = texts(help.lines(config.get().keymaps, 40))
   local headings = {}
   for _, line in ipairs(lines) do
      if line:match("^%u") then headings[#headings + 1] = line end
      assert(vim.api.nvim_strwidth(line) <= 40, line)
   end
   t.equal({ "Emails", "Reading", "Writing" }, headings)
end)

t.test("? opens a centered window with square corners that q, Escape and ? close", function()
   config.setup()
   local previous = vim.api.nvim_get_current_win()
   for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
      help.open(config.get().keymaps)
      local view = assert(shown(), "the help should open")
      t.equal(view.winid, vim.api.nvim_get_current_win())
      t.equal(true, help.is_open())
      t.equal(false, vim.bo[view.bufnr].modifiable)
      local row, col = unpack(vim.api.nvim_win_get_position(view.winid))
      local width, height = vim.api.nvim_win_get_width(view.winid), vim.api.nvim_win_get_height(view.winid)
      local geometry = vim.inspect({ row, col, width, height })
      assert(math.abs(col + width / 2 - vim.o.columns / 2) <= 3, geometry)
      assert(math.abs(row + height / 2 - vim.o.lines / 2) <= 3, geometry)
      t.equal(#view.lines, height)
      local frame
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
         local first = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(winid), 0, 1, false)[1] or ""
         if first:find("■ Keybindings ■", 1, true) then frame = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(winid), 0, -1, false) end
      end
      assert(frame, "the title should be on the border")
      t.equal("┌", frame[1]:sub(1, 3))
      t.equal("└", frame[#frame]:sub(1, 3))
      assert(frame[#frame]:find("q close", 1, true), frame[#frame])
      press(lhs)
      t.equal(nil, shown())
      t.equal(false, help.is_open())
      t.equal(previous, vim.api.nvim_get_current_win())
   end
end)

t.test("leaving the window closes the help, and a short editor scrolls it", function()
   config.setup()
   local previous = vim.api.nvim_get_current_win()
   help.open(config.get().keymaps)
   vim.api.nvim_set_current_win(previous)
   flush()
   t.equal(nil, shown())

   vim.o.lines = 14
   help.open(config.get().keymaps)
   local view = assert(shown())
   assert(vim.api.nvim_win_get_height(view.winid) < #view.lines, "the window should fit the editor")
   help.close()
   t.equal(nil, shown())
   vim.o.lines = 40
end)

t.finish("help_spec")

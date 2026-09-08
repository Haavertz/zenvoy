vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")

-- A separate event loop exercises insert/normal mappings as actual keystrokes.
local child = vim.fn.jobstart({
   vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE", "-n",
}, { rpc = true })
assert(child > 0, "failed to start composer input Neovim")

local function lua(code, ...)
   return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end

local function wait_for(code, description)
   assert(vim.wait(1000, function() return lua(code) end, 10), description)
end

local function input(keys)
   vim.rpcrequest(child, "nvim_input", keys)
end

local function field(name, mode)
   wait_for(("return vim.b.zenvoy_compose_field == %q and vim.api.nvim_get_mode().mode == %q"):format(name, mode),
      "expected " .. name .. " in " .. mode .. " mode")
end

t.test("real input cycles all fields, preserves editing modes, and confirms discard", function()
   lua([[
      vim.o.runtimepath = ...
      vim.o.columns, vim.o.lines = 80, 24
      vim.o.timeoutlen, vim.o.ttimeoutlen = 50, 10
      _G.choices = {}
      _G.previous_win = vim.api.nvim_get_current_win()
      _G.windows_before = #vim.api.nvim_list_wins()
      _G.composer = require("zenvoy.ui.composer").new({
         choose = function(items, options, callback)
            table.insert(_G.choices, { items = items, options = options, callback = callback })
         end,
      })
      _G.composer:open()
   ]], vim.o.runtimepath)
   field("to", "i")
   input("alice@example.test<Tab>")
   field("cc", "i")
   input("bob@example.test<Tab>")
   field("bcc", "i")
   input("private@example.test<Tab>")
   field("subject", "i")
   input("A draft<Tab>")
   field("body", "i")
   input("Hello<CR>Second line<Tab>")
   field("to", "i")
   input("<S-Tab>")
   field("body", "i")
   t.equal("Hello\nSecond line", lua([[
      return table.concat(vim.api.nvim_buf_get_lines(_G.composer.session.fields.body.bufnr, 0, -1, false), "\n")
   ]]))
   t.equal("alice@example.test", lua([[
      return vim.api.nvim_buf_get_lines(_G.composer.session.fields.to.bufnr, 0, -1, false)[1]
   ]]))

   -- Insert Escape is native: it leaves insert mode and does not close the form.
   input("<Esc>")
   field("body", "n")
   t.equal(0, lua("return #_G.choices"))
   input("<Tab>")
   field("to", "n")
   input("<S-Tab>")
   field("body", "n")
   input("q")
   wait_for("return #_G.choices == 1", "normal q should ask to discard edits")
   t.equal(true, lua("return _G.composer:is_open()"))
   lua('_G.choices[1].callback("Keep editing")')
   field("body", "n")
   input("<Esc>")
   wait_for("return #_G.choices == 2", "normal Escape should ask to discard edits")
   lua('_G.choices[2].callback("Discard")')
   wait_for("return not _G.composer:is_open()", "accepted discard should close composer")
   t.equal(true, lua("return vim.api.nvim_get_current_win() == _G.previous_win"))
   t.equal(true, lua("return #vim.api.nvim_list_wins() == _G.windows_before"))
end)

t.test("insert Ctrl-s confirms a completed draft without inserting control text", function()
   lua([[
      _G.choices, _G.sends = {}, {}
      _G.composer = require("zenvoy.ui.composer").new({
         choose = function(items, options, callback)
            table.insert(_G.choices, { items = items, options = options, callback = callback })
         end,
         send = function(draft, callback)
            table.insert(_G.sends, { draft = draft, callback = callback })
         end,
         notify = function() end,
      })
      _G.composer:open()
   ]])
   field("to", "i")
   input("alice@example.test<Tab><Tab><Tab>")
   field("subject", "i")
   input("Keyboard send<Tab>Hello<C-s>")
   wait_for("return #_G.choices == 1", "insert Ctrl-s should confirm send")
   t.equal(0, lua("return #_G.sends"))
   lua('_G.choices[1].callback("Send")')
   t.equal(1, lua("return #_G.sends"))
   t.equal("Hello", lua("return _G.sends[1].draft.body"))
   t.equal("Keyboard send", lua("return _G.sends[1].draft.subject"))
   lua("_G.sends[1].callback(nil)")
   wait_for("return not _G.composer:is_open()", "successful send should close composer")
end)

vim.fn.jobstop(child)
t.finish("composer_input_spec")

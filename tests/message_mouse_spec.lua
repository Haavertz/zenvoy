vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")

-- A separate event loop is needed: -l scripts cannot process normal-mode input
-- while they are running. RPC exercises real mouse events and buffer mappings.
local child = vim.fn.jobstart({
   vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE", "-n",
}, { rpc = true })
assert(child > 0, "failed to start mouse test Neovim")
local function lua(code, ...)
   return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end

t.test("mouse clicks open and switch emails, including from another pane", function()
   lua([[
      vim.o.runtimepath = ...
      vim.o.columns, vim.o.lines = 140, 50
      vim.o.mouse = "a"
      _G.selections = {}
      local ui = require("zenvoy.ui")
      ui.set_message_reader(function(id, callback)
         table.insert(_G.selections, id)
         callback(nil, { subject = id, from = {}, to = {}, cc = {}, body = "Hello!" })
      end)
      ui.set_envelopes({ { id = "first", subject = "First" }, { id = "second", subject = "Second" } })
      ui.create()
   ]], vim.o.runtimepath)

   for row, id in ipairs({ "first", "second" }) do
      local pos = lua([[
         vim.cmd.redraw()
         return vim.fn.screenpos(require("zenvoy.state").listing_popup.winid, ..., 1)
      ]], row)
      assert(pos.row > 0 and pos.col > 0, "email row must be on screen")
      for _, action in ipairs({ "press", "release" }) do
         vim.rpcrequest(child, "nvim_input_mouse", "left", action, "", 0, pos.row - 1, pos.col - 1)
      end
      assert(vim.wait(500, function()
         return lua("return #_G.selections") == row
      end, 10), "click did not open " .. id)
      t.equal(id, lua("return _G.selections[#_G.selections]"))
      t.equal(true, lua([[
         return vim.api.nvim_get_current_win() == require("zenvoy.state").email_popup.winid
      ]]))
   end
   lua('require("zenvoy.ui").close()')
end)

vim.fn.jobstop(child)
t.finish("message_mouse_spec")

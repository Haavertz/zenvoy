vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local child = vim.fn.jobstart({ vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE", "-n" }, { rpc = true })
assert(child > 0, "failed to start keyboard test Neovim")
local function lua(code, ...)
   return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end
local function input(keys)
   vim.rpcrequest(child, "nvim_input", keys)
end
local function wait_for(code)
   assert(vim.wait(1000, function() return lua(code) end, 10), code)
end

t.test("s and j change real sidebar focus and mailbox content without opening a message", function()
   lua([[
      vim.o.runtimepath = ...
      vim.o.columns, vim.o.lines = 140, 50
      _G.loaded, _G.reads = {}, {}
      local ui = require("zenvoy.ui")
      ui.set_mailbox_loader(function(id, callback)
         table.insert(_G.loaded, id)
         callback(nil, { { id = "same-id", subject = id } })
      end)
      ui.set_message_reader(function(id, callback, mailbox)
         table.insert(_G.reads, { id = id, mailbox = mailbox })
         callback(nil, { from = {}, to = {}, cc = {}, subject = mailbox, body = "Hello" })
      end)
      ui.set_mailboxes({ { id = "native/inbox" }, { id = "native/archive" } })
      ui.set_envelopes({ { id = "initial" } })
      ui.create()
   ]], vim.o.runtimepath)
   input("s")
   wait_for([[return vim.api.nvim_get_current_win() == require("zenvoy.state").sidebar_popup.winid]])
   input("j")
   wait_for([[return _G.loaded[#_G.loaded] == "native/archive"]])
   t.equal("native/archive", lua([[return require("zenvoy.state").envelopes[1].subject]]))
   t.equal(0, lua("return #_G.reads"))
   input("<CR>")
   wait_for([[return vim.api.nvim_get_current_win() == require("zenvoy.state").listing_popup.winid]])
   input("<CR>")
   wait_for("return #_G.reads == 1")
   t.equal({ id = "same-id", mailbox = "native/archive" }, lua("return _G.reads[1]"))
   input("s")
   wait_for([[return vim.api.nvim_get_current_win() == require("zenvoy.state").sidebar_popup.winid]])
   input("k")
   wait_for([[return _G.loaded[#_G.loaded] == "native/inbox"]])
   t.equal(false, lua([[return require("zenvoy.state").email_visible]]))
   lua([[require("zenvoy.ui").close()]])
end)

t.test("batched open and sidebar/back inputs drain layout work before removing the message", function()
   lua([[
      _G.layout_errors = {}
      local schedule = vim.schedule
      vim.schedule = function(callback)
         schedule(function()
            local ok, err = pcall(callback)
            if not ok then table.insert(_G.layout_errors, tostring(err)) end
         end)
      end
   ]])
   for _, action in ipairs({ "s", "q" }) do
      lua([[
         local ui = require("zenvoy.ui")
         ui.set_mailbox_loader(function(id, callback) callback(nil, { { id = "selected" } }) end)
         ui.set_message_reader(function(_, callback)
            callback(nil, { from = {}, to = {}, cc = {}, body = "Hello" })
         end)
         ui.set_mailboxes({ { id = "native/inbox" } })
         ui.set_envelopes({ { id = "selected" } })
         ui.create()
      ]])
      input("<CR>" .. action)
      wait_for([[return not require("zenvoy.state").email_visible]])
      -- Let both the layout positioning callback and folder debounce complete.
      vim.wait(220, function() return false end, 10)
      t.equal({}, lua("return _G.layout_errors"))
      local expected = action == "s" and "sidebar_popup" or "listing_popup"
      t.equal(true, lua([[return vim.api.nvim_get_current_win() == require("zenvoy.state")[...].winid]], expected))
      lua([[require("zenvoy.ui").close()]])
   end
end)

vim.fn.jobstop(child)
t.finish("mailbox_input_spec")

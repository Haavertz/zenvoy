vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Exercise :Zenvoy with the real UI and controlled process results; no mailbox access.
local original_system, original_readable, original_writefile = vim.system, vim.fn.filereadable, vim.fn.writefile
local exits, notifications, welcome = {}, {}, nil
vim.system = function(_, _, on_exit)
   exits[#exits + 1] = on_exit
   return { mocked = true }
end
vim.fn.filereadable = function() return 1 end
vim.notify = function(message) notifications[#notifications + 1] = message end
package.loaded["zenvoy.ui.welcome"] = { create = function(callback) welcome = callback end }

local app, state = require("zenvoy"), require("zenvoy.state")
dofile("plugin/zenvoy.lua")

local function indicator()
   local border = state.sidebar_popup and state.sidebar_popup.border
   if not border or not vim.api.nvim_buf_is_valid(border.bufnr) then return end
   local row = vim.api.nvim_win_get_height(border.winid) - 1
   local footer = vim.api.nvim_buf_get_lines(border.bufnr, row, row + 1, false)[1]
   return footer:find("Loading", 1, true) and border.bufnr or nil
end

local function complete(index, result)
   exits[index](result)
   vim.wait(30, function() return false end, 5)
end

local success = {
   code = 0, stderr = "",
   stdout = '{"mailboxes":[{"id":"Inbox"}],"envelopes":[]}',
}
vim.cmd.Zenvoy()
assert(indicator(), "opening Zenvoy must immediately show pending work")
assert(vim.api.nvim_get_current_win() == state.listing_popup.winid)
complete(1, success)
assert(not indicator(), "success must stop loading")
assert(state.mailboxes[1].id == "Inbox")
app.close()

vim.cmd.Zenvoy()
complete(2, { code = 1, stdout = "", stderr = "Himalaya failed" })
assert(not indicator(), "process errors must stop loading")
assert(notifications[#notifications] == "Zenvoy: Himalaya failed")
app.close()

vim.cmd.Zenvoy()
complete(3, { code = 0, stdout = "invalid-json", stderr = "" })
assert(not indicator(), "invalid JSON must stop loading")
assert(notifications[#notifications]:find("Invalid Zenvoy JSON", 1, true))
app.close()

vim.cmd.Zenvoy()
for _, map in ipairs(vim.api.nvim_buf_get_keymap(state.listing_popup.bufnr, "n")) do
   if map.lhs == "q" then map.callback() end
end
assert(not indicator(), "q must remove the indicator")
vim.cmd.Zenvoy()
local newer = indicator()
local mailboxes = state.mailboxes
complete(4, { code = 0, stderr = "", stdout = '{"mailboxes":[{"id":"Stale"}],"envelopes":[]}' })
assert(indicator() == newer, "old completion must not stop new loading")
assert(state.mailboxes == mailboxes, "old completion must not replace current data")
complete(5, success)
app.close()

vim.system = function() error("cannot spawn Go") end
vim.cmd.Zenvoy()
assert(not indicator(), "synchronous process failure must stop loading")
assert(notifications[#notifications]:find("cannot spawn Go", 1, true))
app.close()

vim.system = function(_, _, on_exit) exits[#exits + 1] = on_exit; return {} end
vim.fn.filereadable = function() return 0 end
vim.fn.writefile = function() return 0 end
vim.cmd.Zenvoy()
assert(welcome and not indicator(), "first-run work must wait for the sidebar to exist")
welcome()
assert(indicator(), "entering the sidebar must show work already in progress")
complete(#exits, success)
assert(not indicator())
app.close()

vim.system, vim.fn.filereadable, vim.fn.writefile = original_system, original_readable, original_writefile
print("loading_spec: :Zenvoy success, errors, close/reopen, spawn failure and welcome passed")

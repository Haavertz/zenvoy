vim.opt.runtimepath:prepend(vim.fn.getcwd())

local Popup = require("nui.popup")
local Activity = require("zenvoy.ui.activity")
local sidebar = Popup({
   relative = "editor", position = "50%", size = { width = 30, height = 16 },
   border = { style = "rounded", text = { top = " Folders ", top_align = "center" } },
})
sidebar:mount()
vim.api.nvim_buf_set_lines(sidebar.bufnr, 0, -1, false, { "Inbox", "  Spam" })

local activity = Activity.new()
local finish = activity:start({ "Loading sidebar", "Loading emails" })
assert(not activity.timer, "pending work must wait for the sidebar to mount")
local window_count = #vim.api.nvim_list_wins()
local title = vim.api.nvim_buf_get_lines(sidebar.border.bufnr, 0, 1, false)[1]
activity:attach(sidebar)

local function footer(popup)
   local border = (popup or sidebar).border
   local row = vim.api.nvim_win_get_height(border.winid) - 1
   return vim.api.nvim_buf_get_lines(border.bufnr, row, row + 1, false)[1]
end

local function centered()
   local line = footer()
   local first, last = line:find(" ", 1, true), line:match(".*() ")
   assert(first and last, "activity must appear inside the bottom border")
   local left = vim.fn.strdisplaywidth(line:sub(1, first - 1))
   local right = vim.fn.strdisplaywidth(line:sub(last + 1))
   assert(math.abs(left - right) <= 1, "footer title must be centered: " .. line)
   assert(#vim.api.nvim_list_wins() == window_count, "activity must not create an overlay window")
end

local focused = vim.api.nvim_get_current_win()
assert(footer():find("Loading sidebar", 1, true), footer())
centered()
local first = footer()
assert(vim.wait(500, function() return footer() ~= first end, 10), "spinner must animate")
assert(vim.wait(1500, function() return footer():find("Loading emails", 1, true) end, 10),
   "footer must cycle through concurrent loading labels")
assert(vim.api.nvim_get_current_win() == focused, "animation must preserve focus")
assert(vim.api.nvim_buf_get_lines(sidebar.border.bufnr, 0, 1, false)[1] == title, "top title must remain intact")

local finish_send = activity:start("Sending compose")
assert(finish(), "first completion must succeed")
assert(not finish(), "completion must be idempotent")
assert(footer():find("Sending compose", 1, true), footer())
sidebar:update_layout({ size = { width = 24, height = 10 } })
activity:render()
centered()

local timer = activity.timer
assert(finish_send())
assert(not activity.timer, "idle indicator must release its timer")
assert(timer:is_closing(), "idle timer must close")
assert(not footer():find(" ", 1, true), "idle footer must return to an empty border")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(sidebar.bufnr, 0, -1, false), { "Inbox", "  Spam" }))

local cancelled = activity:start("Loading emails")
timer = activity.timer
sidebar:unmount()
assert(not activity.timer, "closing sidebar must clean up the indicator")
assert(timer:is_closing())
assert(not cancelled(), "late completion must not affect a closed session")

local next_sidebar = Popup({
   relative = "editor", position = "50%", size = { width = 20, height = 10 },
   border = { style = "rounded", text = { top = " Folders " } },
})
next_sidebar:mount()
activity:attach(next_sidebar)
local next_finish = activity:start("Loading confirmação de inscrição 📰")
assert(not cancelled(), "old completion must not clear a newer operation")
assert(footer(next_sidebar):find("Loading", 1, true))
assert(vim.fn.strdisplaywidth(footer(next_sidebar)) == 22, "long labels must fit within the border")
assert(vim.json.decode(vim.json.encode(footer(next_sidebar))), "truncation must preserve UTF-8")
activity:clear()
assert(not footer(next_sidebar):find(" ", 1, true), "clear must remove a visible footer")
next_finish()
next_sidebar:unmount()

print("activity_spec: bottom title, animation, centering, cycling, resize and cleanup passed")

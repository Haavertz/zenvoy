vim.opt.runtimepath:prepend(vim.fn.getcwd())

local sidebar = require("zenvoy.ui.sidebar")
local bufnr = vim.api.nvim_create_buf(false, true)

vim.bo[bufnr].modifiable = false
vim.bo[bufnr].readonly = true

sidebar.render(bufnr, {
   { id = "Inbox", name = "Inbox" },
   { id = "[Gmail]/All Mail", name = "All Mail" },
   { id = "[Gmail]/Labels", name = "Labels" },
   { id = "[Gmail]/Labels/Work", name = "Work" },
})

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

assert(vim.deep_equal(lines, {
   "Inbox",
   "  All Mail",
   "  Labels",
   "    Work",
}), vim.inspect(lines))
assert(vim.bo[bufnr].modifiable == false, "sidebar buffer must be non-modifiable after rendering")
assert(vim.bo[bufnr].readonly == true, "sidebar buffer must be read-only after rendering")

print("sidebar_spec: 1 test passed")

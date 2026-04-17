local M = {}

M.config = {
  wrap_folder_navigation = false,
  icons_enable = true,
  keymaps = {
    ['q'] = "close_or_back",
    ['c'] = "compose",
    ['r'] = "reply",
    ['<CR>'] = "enter"
  },
}

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

return M

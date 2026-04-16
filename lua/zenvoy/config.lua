local M = {}

M.config = {
  wrap_folder_navigation = false,
  icons_enable = true,
  keymaps = {
    listing = {
      ['q'] = "close",
      ['<CR>'] = "enter_email"
    },
  },
}

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

return M

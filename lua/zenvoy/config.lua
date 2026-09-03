local M = {}

M.config = {
   sidebar = {
      width = 30,
   },
   wrap_folder_navigation = true,
   icons_enable = true,
   keymaps = {
      listing = {
         ["q"] = "close",
         ["<Esc>"] = "close",
         ["c"] = "compose",
         ["r"] = "reply",
         ["<CR>"] = "open_email",
      },
      email = {
         ["q"] = "close",
         ["<Esc>"] = "close",
         ["<BS>"] = "close_email",
      },
   },
}

function M.setup(opts)
   M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

return M

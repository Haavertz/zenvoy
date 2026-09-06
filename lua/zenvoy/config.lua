local defaults = {
   sidebar = {
      width = 30,
   },
   wrap_folder_navigation = false,
   icons_enable = false,
   keymaps = {
      ["q"] = "close_or_back",
      ["c"] = false,
      ["r"] = false,
      ["<CR>"] = "enter",
   },
}

local M = {
   config = vim.deepcopy(defaults),
}

function M.setup(opts)
   M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get()
   return M.config
end

return M

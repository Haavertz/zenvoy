local defaults = {
   himalaya = {
      executable = "himalaya",
      timeout = 30000,
      page_size = 50,
   },
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
   local options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
   local himalaya = options.himalaya
   assert(type(himalaya) == "table", "himalaya must be a table")
   assert(type(himalaya.executable) == "string" and himalaya.executable:find("%S"),
      "himalaya.executable must be a non-empty string")
   for _, name in ipairs({ "timeout", "page_size" }) do
      local value = himalaya[name]
      assert(type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0,
         "himalaya." .. name .. " must be a positive integer")
   end
   M.config = options
end

function M.get()
   return M.config
end

return M

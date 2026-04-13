local config = require("zenvoy.config")

local M = {}

function M.setup(opts)
  vim.api.nvim_create_user_command("Zenvoy", function() 
    config.setup(opts)
  end, {})
end

return M

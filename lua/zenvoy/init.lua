local config = require("zenvoy.config")
local state = require("zenvoy.states")
local welcome = require("zenvoy.ui.welcome")

local M = {}
local state_file = vim.fn.stdpath("data") .. "/zenvoy_welcome_seen"

function M.setup(opts)
  config.setup(opts)
end

function M.open()
  if state.is_open then return end

  if vim.fn.filereadable(state_file) == 0 then
    welcome.show_welcome()
    vim.fn.writefile({"seen"}, state_file)
  end

end

return M

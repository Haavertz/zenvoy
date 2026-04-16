local config = require("zenvoy.config")
local state = require("zenvoy.states")

local M = {}

function M.setup(opts)
  config.setup(opts)
end

function M.open()
  if state.is_open then
      vim.notify("Zenvoy is already open", vim.log.levels.WARN)
      return
  end
end

return M

local layout = require("zenvoy.ui.layout")

local M = {}

function M.open()
  layout.show_email()
end

function M.close()
  layout.hide_email()
end

return M

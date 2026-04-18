local M = {}

-- local state = require("zenvoy.states")

local Popup = require("nui.popup")
-- local Layout = require("nui.layout")

function M.create()
  local sidebar = Popup ({
    position = "50%",
    size = {
      width = 150,
      height = 40,
    },
    enter = false,
    focusable = true,
    border = {
      style = "rounded",
      text = {
        top = " Folders ",
        top_align = "center",
      },
    },
    win_options = {
      cursorline = true
    },
    zindex = 49,
  })
  sidebar:mount()
end

return M

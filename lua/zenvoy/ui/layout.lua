local M = {}

local Popup = require("nui.popup")
local Text = require("nui.text")

---@param title string
---@return table Popup
function M.create_popup(title)
  return Popup({
    enter = false,
    focusable = true,
    relative = "editor",
    border = {
      style = "rounded",
      text = {
        top = Text(string.format(" ■ %s ■ ", title), "FloatTitle"),
        top_align = "center",
      },
    },
    win_options = {
      cursorline = true,
    },
    buf_options = {
      modifiable = false,
      readonly = true,
    },
    zindex = 49,
  })
end

return M

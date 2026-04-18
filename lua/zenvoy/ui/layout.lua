local M = {}

local state = require("zenvoy.states")

local Popup = require("nui.popup")
local Layout = require("nui.layout")
local Text = require("nui.text")


function M.create()
  local aside = Popup ({
    enter = false,
    focusable = true,
    relative = "editor",
    border = {
      style = "rounded",
      text = {
        top = Text(" Folders ", "FloatBorder"),
        top_align = "center",
      },
    },
    win_options = {
      cursorline = true
    },
    buf_options = {
      modifiable = false,
      readonly = true,
    },
    zindex = 49,
  })

  local email = Popup ({
    enter = false,
    focusable = true,
    relative = "editor",
    border = {
      style = "rounded",
      text = {
        top = Text(" Emails ", "FloatBorder"),
        top_align = "center",
      },
    },
    win_options = {
      cursorline = true
    },
    buf_options = {
      modifiable = false,
      readonly = true,
    },
    zindex = 49,
  })

  local aside_pct = state.aside or 25
  local email_pct = 100 - aside_pct

  local main = Layout({
      position = "50%",
      relative = "editor",
      size = {
        width = "90%",
        height = "80%",
      },
    },
    Layout.Box({
      Layout.Box(aside, { size = tostring(aside_pct) .. "%" }),
      Layout.Box(email, { size = tostring(email_pct) .. "%" })
    }, { dir = "row" })
  )
  main:mount()
end

return M

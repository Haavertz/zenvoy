local M = {}

local state = require("zenvoy.states")

local Popup = require("nui.popup")
local Layout = require("nui.layout")
local Text = require("nui.text")

---@param title string 
---@return table Popup
local function create_popup(title)
  return Popup({
    enter = false,
    focusable = true,
    relative = "editor",
    border = {
      style = "rounded",
      text = {
        top = Text(string.format(" ■ %s ■ ", title), "FloatBorder"),
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

function M.create()
  local aside = create_popup("Folders")
  local email = create_popup("Emails")
  local envelope_email = create_popup("Name Email")

  local aside_pct = (type(state.aside) == "number" and state.aside > 0 and state.aside < 100)
      and state.aside
      or 20
  local email_pct = 100 - aside_pct

  local main = Layout(
    {
      position = "50%",
      relative = "editor",
      size = {
        width = "90%",
        height = "80%",
      },
    },
    Layout.Box({
      Layout.Box(aside, { size = aside_pct .. "%" }),
      Layout.Box(email, { size = email_pct .. "%" }),
    }, { dir = "row" })
  )

  main:mount()

  if state.sidebar_popup then
    main:update(Layout.Box({
      Layout.Box(aside, { size = aside_pct .. "%" }),
      Layout.Box({
        Layout.Box(email, { size = "40%" }),
        Layout.Box(envelope_email, { size = "61%" })
      }, { dir = "col", size = email_pct .. "%" })
    }, { dir = "row" }))
  end
end

return M

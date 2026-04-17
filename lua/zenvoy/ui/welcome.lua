local M = {}

local Popup = require("nui.popup")

-- local Line = require("nui.line")
-- local Text = require("nui.text")

function M.show_welcome()
    local main_win = vim.api.nvim_get_current_win()

    local total_height = vim.api.nvim_win_get_height(main_win)
    local total_width = vim.api.nvim_win_get_width(main_win)

    local win_w = math.ceil(total_width * 0.24)
    local win_h = math.ceil(total_height * 0.55)

    local popup = Popup({
        enter = true,
        focusable = true,
        border = {
            style = "rounded",
            padding = {
                top = 1,
                bottom = 1,
                left = 2,
                right = 2,
            },
        },
        position = "50%",
        size = {
            width = win_w,
            height = win_h,
        },
        win_options = {
            winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
        },
    })

    popup:mount()
end

return M

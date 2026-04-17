local M = {}

local Popup = require("nui.popup")
local Line = require("nui.line")
local Text = require("nui.text")

function M.show_welcome()
    local main_win = vim.api.nvim_get_current_win()

    local total_height = vim.api.nvim_win_get_height(main_win)
    local total_width = vim.api.nvim_win_get_width(main_win)

    local win_w = math.ceil(total_width * 0.3)
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
    local lines = {}

    local title = Line()
    title:append("Welcome to Zenvoy! 📫", "Directory")
    table.insert(lines, title)
    table.insert(lines, Line())

    table.insert(lines, Line({ Text("Your email workflow, now completely keyboard-driven.", "String") }))
    table.insert(lines, Line({ Text("Stay focused. No context switching, just a zen inbox.") }))
    table.insert(lines, Line())

    table.insert(lines, Line({ Text("Quick start", "Directory") }))
    table.insert(lines, Line({ Text("  j/k  | navigate      <CR> | open email") }))
    table.insert(lines, Line({ Text("  c    | compose         r  | reply") }))
    table.insert(lines, Line({ Text("  q    | close") }))
    table.insert(lines, Line())

    local tip_line = Line()
    tip_line:append("Tip: ", "WarningMsg")
    tip_line:append("Press ", "Comment")
    tip_line:append("?", "String")
    tip_line:append(" anytime to see all available keybindings.", "Comment")
    table.insert(lines, tip_line)

    table.insert(lines, Line())
    table.insert(lines, Line({ Text("Press any key to enter your inbox...", "Comment") }))

    for i, line in ipairs(lines) do
        line:render(popup.bufnr, -1, i)
    end

    local close_keys = { "<Esc>", "q", "<CR>", "<Space>" }

    for _, key in ipairs(close_keys) do
        popup:map("n", key, function()
            popup:unmount()
        end, { noremap = true })
    end
end

return M

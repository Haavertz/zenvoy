local M = {}

local Popup = require("nui.popup")
local Line = require("nui.line")
local Text = require("nui.text")
local config = require("zenvoy.config")
local keymaps = require("zenvoy.keymaps")

local function key_label(action_name)
    local keys = keymaps.keys_for(config.get().keymaps, action_name)

    if #keys == 0 then
        return "-"
    end

    return table.concat(keys, "/")
end

function M.create(on_close)
    local main_win = vim.api.nvim_get_current_win()

    local total_height = vim.api.nvim_win_get_height(main_win)
    local total_width = vim.api.nvim_win_get_width(main_win)

    local win_w = math.ceil(total_width * 0.2)
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

    local ti = table.insert

    local title = Line()
    title:append("Welcome to Zenvoy! 📫", "Directory")
    ti(lines, title)
    ti(lines, Line())

    ti(lines, Line({ Text("Your email workflow, now completely keyboard-driven.", "String") }))
    ti(lines, Line({ Text("Stay focused. No context switching, just a zen inbox.") }))
    ti(lines, Line())

    ti(lines, Line({ Text("Quick start", "Directory") }))
    ti(lines, Line({ Text(string.format("  j/k | navigate      %s | open email", key_label("enter"))) }))
    ti(lines, Line({ Text(string.format("  %s | compose       %s | reply", key_label("compose"), key_label("reply"))) }))
    ti(lines, Line({ Text(string.format("  %s | close or go back", key_label("close_or_back"))) }))
    ti(lines, Line())

    local tip_line = Line()
    tip_line:append("Tip: ", "WarningMsg")
    tip_line:append("Press ", "Comment")
    tip_line:append("?", "String")
    tip_line:append(" anytime to see all available keybindings.", "Comment")
    table.insert(lines, tip_line)

    ti(lines, Line())
    ti(lines, Line({ Text("Press any key to enter your inbox...", "Comment") }))

    for i, line in ipairs(lines) do
        line:render(popup.bufnr, -1, i)
    end

    local close_keys = { "<Esc>", "q", "<CR>", "<Space>" }

    for _, key in ipairs(close_keys) do
        popup:map("n", key, function()
            popup:unmount()
            if on_close then
              on_close()
            end
        end, { noremap = true })
    end
end

return M

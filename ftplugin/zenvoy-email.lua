local bufnr = vim.api.nvim_get_current_buf()
local config = require("zenvoy.config")
local keymap = require("zenvoy.utils.keymap")
local email = require("zenvoy.email")
local zenvoy = require("zenvoy")

local actions = {
  close = function()
    zenvoy.close()
  end,
  close_email = function()
    email.close()
  end,
}

keymap.apply(bufnr, config.config.keymaps.email, actions)

local bufnr = vim.api.nvim_get_current_buf()
local config = require("zenvoy.config")
local keymap = require("zenvoy.utils.keymap")
local email = require("zenvoy.email")
local zenvoy = require("zenvoy")

local actions = {
  close = function()
    zenvoy.close()
  end,
  open_email = function()
    email.open()
  end,
}

keymap.apply(bufnr, config.config.keymaps.listing, actions)

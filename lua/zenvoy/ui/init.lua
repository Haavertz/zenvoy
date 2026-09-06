local M = {}

local state = require("zenvoy.state")
local layout = require("zenvoy.ui.layout")
local keymap = require("zenvoy.keymaps")
local config = require("zenvoy.config")
local command_factory = require("zenvoy.commands")
local sidebar = require("zenvoy.ui.sidebar")

local Layout = require("nui.layout")

local function focus(popup)
   if popup and popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
      vim.api.nvim_set_current_win(popup.winid)
   end
end

local function create_box()
   local sidebar_width = config.get().sidebar.width

   if state.email_visible then
      return Layout.Box({
         Layout.Box(state.sidebar_popup, { size = sidebar_width }),
         Layout.Box({
            Layout.Box(state.listing_popup, { size = "50%" }),
            Layout.Box(state.email_popup, { grow = 1 }),
         }, { dir = "col", grow = 1 }),
      }, { dir = "row" })
   end

   return Layout.Box({
      Layout.Box(state.sidebar_popup, { size = sidebar_width }),
      Layout.Box(state.listing_popup, { grow = 1 }),
   }, { dir = "row" })
end

local commands = command_factory.create({
   state = state,
   create_box = create_box,
   focus = focus,
   current_buffer = vim.api.nvim_get_current_buf,
   notify = vim.notify,
})

local function apply_keymaps(popup)
   keymap.apply(popup.bufnr, config.get().keymaps, commands)
end

M.close = commands.close

function M.set_mailboxes(mailboxes)
   state.mailboxes = mailboxes or {}

   if state.sidebar_popup then
      sidebar.render(state.sidebar_popup.bufnr, state.mailboxes)
   end
end

function M.create()
   if state.is_open then
      focus(state.listing_popup)
      return state.layout
   end

   state.sidebar_popup = layout.create_popup("Folders")
   state.listing_popup = layout.create_popup("Emails")
   state.email_popup = layout.create_popup("")
   state.email_visible = false

   local main = Layout(
      {
         position = "50%",
         relative = "editor",
         size = {
            width = "90%",
            height = "80%",
         },
      },
      create_box()
   )

   state.layout = main
   main:mount()
   state.is_open = true

   vim.bo[state.sidebar_popup.bufnr].filetype = "zenvoy-folder-listing"
   vim.bo[state.listing_popup.bufnr].filetype = "zenvoy-envelope-listing"
   vim.bo[state.email_popup.bufnr].filetype = "zenvoy-email"

   sidebar.render(state.sidebar_popup.bufnr, state.mailboxes)

   apply_keymaps(state.sidebar_popup)
   apply_keymaps(state.listing_popup)
   apply_keymaps(state.email_popup)

   focus(state.listing_popup)

   return main
end

return M

local M = {}

local config = require("zenvoy.config")
local state = require("zenvoy.states")

local Popup = require("nui.popup")
local Layout = require("nui.layout")
local Text = require("nui.text")

local augroup = vim.api.nvim_create_augroup("ZenvoyLayout", { clear = true })
local modal_windows = {}

local function get_size()
  local columns = vim.o.columns
  local lines = vim.o.lines

  return {
    width = columns < 90 and "98%" or "90%",
    height = lines < 28 and "95%" or "80%",
    stacked = columns < 90,
  }
end

local function create_boxes(sidebar, listing, email, sidebar_width, stacked, email_visible)
  if stacked then
    if email_visible then
      return Layout.Box({
        Layout.Box(sidebar, { size = "25%" }),
        Layout.Box(listing, { size = "35%" }),
        Layout.Box(email, { size = "40%" }),
      }, { dir = "col" })
    end

    return Layout.Box({
      Layout.Box(sidebar, { size = "35%" }),
      Layout.Box(listing, { size = "65%" }),
    }, { dir = "col" })
  end

  if email_visible then
    return Layout.Box({
      Layout.Box(sidebar, { size = sidebar_width }),
      Layout.Box({
        Layout.Box(listing, { size = "50%" }),
        Layout.Box(email, { size = "50%" })
      }, { dir = "col", grow = 1 })
    }, { dir = "row" })
  end

  return Layout.Box({
    Layout.Box(sidebar, { size = sidebar_width }),
    Layout.Box(listing, { grow = 1 }),
  }, { dir = "row" })
end

local function is_zenvoy_win(winid)
  for _, zenvoy_winid in ipairs(modal_windows) do
    if winid == zenvoy_winid and vim.api.nvim_win_is_valid(winid) then
      return true
    end
  end

  return false
end

local function remember_windows(...)
  modal_windows = {}

  for _, popup in ipairs({ ... }) do
    if popup and popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
      table.insert(modal_windows, popup.winid)
    end
  end
end

local function focus_popup(popup)
  if popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
    vim.api.nvim_set_current_win(popup.winid)
  end
end

local function update_layout()
  if not state.layout then
    return
  end

  local size = get_size()
  local sidebar_width = config.config.sidebar.width or 30

  state.layout:update({
    position = "50%",
    relative = "editor",
    size = {
      width = size.width,
      height = size.height,
    },
  }, create_boxes(
    state.sidebar_popup,
    state.main_popup,
    state.email_popup,
    sidebar_width,
    size.stacked,
    state.email_visible
  ))

  remember_windows(
    state.sidebar_popup,
    state.main_popup,
    state.email_visible and state.email_popup or nil
  )
end

function M.close()
  local active_layout = state.layout
  if not active_layout then
    return
  end

  vim.api.nvim_clear_autocmds({ group = augroup })
  modal_windows = {}
  state.is_open = false
  -- state.email_visible = false
  state.layout = nil
  state.sidebar = nil
  state.sidebar_popup = nil
  state.main = nil
  state.main_popup = nil
  state.email = nil
  state.email_popup = nil

  active_layout:unmount()
end

function M.show_email()
  if not state.layout or not state.email_popup then
    return
  end

  if not state.email_visible then
    state.email_visible = true
    update_layout()
  end

  focus_popup(state.email_popup)
end

function M.hide_email()
  if not state.layout or not state.email_visible then
    return
  end

  state.email_visible = false
  update_layout()
  focus_popup(state.main_popup)
end

---@param title string 
---@return table Popup
local function create_popup(title)
  return Popup({
    enter = true,
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
      winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
    },
    buf_options = {
      modifiable = false,
      readonly = true,
    },
    zindex = 49,
  })
end

function M.create()
  local aside = create_popup("Folder")
  local email = create_popup("Email")
  local envelope_email = create_popup("Name Email")
  local size = get_size()

  local sidebar_width = config.config.sidebar.width or 30

  local main = Layout({
      position = "50%",
      relative = "editor",
      size = {
        width = size.width,
        height = size.height,
      },
    },
    create_boxes(aside, email, envelope_email, sidebar_width, size.stacked, state.email_visible) -- remove state.email_visible and set up true
  )

  main:mount()
  state.layout = main
  state.sidebar = aside.bufnr
  state.sidebar_popup = aside
  state.main = email.bufnr
  state.main_popup = email
  state.email = envelope_email.bufnr
  state.email_popup = envelope_email
  state.is_open = true

  vim.bo[aside.bufnr].filetype = "zenvoy-folder-listing"
  vim.bo[email.bufnr].filetype = "zenvoy-envelope-listing"
  vim.bo[envelope_email.bufnr].filetype = "zenvoy-email"

  remember_windows(aside, email)
  focus_popup(email)

  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = augroup,
    callback = function()
      if not state.is_open or is_zenvoy_win(vim.api.nvim_get_current_win()) then
        return
      end

      vim.schedule(function()
        if state.is_open and not is_zenvoy_win(vim.api.nvim_get_current_win()) then
          focus_popup(email)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      update_layout()
      focus_popup(state.email_visible and state.email_popup or state.main_popup)
    end,
  })

  return main
end

return M

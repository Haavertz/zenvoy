local M = {}

local config = require("zenvoy.config")
local state = require("zenvoy.states")

local Popup = require("nui.popup")
local Layout = require("nui.layout")
local Text = require("nui.text")

local augroup = vim.api.nvim_create_augroup("ZenvoyLayout", { clear = true })
local modal_windows = {}

local function clamp(value, min, max)
  return math.max(min, math.min(max, value))
end

local function get_size()
  local columns = vim.o.columns
  local lines = vim.o.lines

  return {
    width = columns < 90 and "98%" or "90%",
    height = lines < 28 and "95%" or "80%",
    stacked = columns < 90,
  }
end

local function create_boxes(aside, email, envelope_email, aside_pct, email_pct, stacked)
  if stacked then
    if state.sidebar_popup then
      return Layout.Box({
        Layout.Box(aside, { size = "25%" }),
        Layout.Box(email, { size = "35%" }),
        Layout.Box(envelope_email, { size = "40%" }),
      }, { dir = "col" })
    end

    return Layout.Box({
      Layout.Box(aside, { size = "35%" }),
      Layout.Box(email, { size = "65%" }),
    }, { dir = "col" })
  end

  if state.sidebar_popup then
    return Layout.Box({
      Layout.Box(aside, { size = aside_pct .. "%" }),
      Layout.Box({
        Layout.Box(email, { size = "50%" }),
        Layout.Box(envelope_email, { size = "50%" })
      }, { dir = "col", size = email_pct .. "%" })
    }, { dir = "row" })
  end

  return Layout.Box({
    Layout.Box(aside, { size = aside_pct .. "%" }),
    Layout.Box(email, { size = email_pct .. "%" }),
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
    if popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
      table.insert(modal_windows, popup.winid)
    end
  end
end

local function focus_popup(popup)
  if popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
    vim.api.nvim_set_current_win(popup.winid)
  end
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
  local aside = create_popup("Folders")
  local email = create_popup("Emails")
  local envelope_email = create_popup("Name Email")
  local size = get_size()

  local aside_w = config.config.aside_w or state.aside
  local aside_pct = (type(aside_w) == "number" and aside_w > 0 and aside_w < 100)
      and aside_w
      or 20
  aside_pct = clamp(aside_pct, 18, 35)
  local email_pct = 100 - aside_pct

  local main = Layout(
    {
      position = "50%",
      relative = "editor",
      size = {
        width = size.width,
        height = size.height,
      },
    },
    create_boxes(aside, email, envelope_email, aside_pct, email_pct, size.stacked)
  )

  main:mount()
  state.is_open = true

  remember_windows(aside, email, envelope_email)
  focus_popup(email)

  local function close()
    vim.api.nvim_clear_autocmds({ group = augroup })
    state.is_open = false
    modal_windows = {}
    main:unmount()
  end

  for _, popup in ipairs({ aside, email, envelope_email }) do
    if popup.bufnr and vim.api.nvim_buf_is_valid(popup.bufnr) then
      popup:map("n", "q", close, { noremap = true })
      popup:map("n", "<Esc>", close, { noremap = true })
    end
  end

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
      local resized = get_size()
      main:update(create_boxes(aside, email, envelope_email, aside_pct, email_pct, resized.stacked))
      remember_windows(aside, email, envelope_email)
      focus_popup(email)
    end,
  })

  return main
end

return M

local M = {}
local active = {}

local function api()
   local ok, image = pcall(require, "image")
   if not ok or type(image.from_file) ~= "function" then return nil end
   return image
end

function M.supported()
   return api() ~= nil
end

---@param path string
---@param target table { buffer: integer, window: integer, row: integer }
---@param callback fun(err: string?)
function M.open(_, path, target, callback)
   local image_api = api()
   if not image_api then
      callback("Install and configure image.nvim with a supported terminal backend")
      return
   end
   local winid, bufnr = target.window, target.buffer
   if not winid or not vim.api.nvim_win_is_valid(winid) or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      callback("The email window is no longer available")
      return
   end

   local ok, result = pcall(function()
      local cursor = vim.api.nvim_win_get_cursor(winid)
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local row = math.max(1, math.min(target.row or cursor[1], line_count))
      vim.api.nvim_win_set_cursor(winid, { row, 0 })
      local created, rendered = pcall(image_api.from_file, path, {
         buffer = bufnr,
         window = winid,
         inline = true,
         with_virtual_padding = true,
      })
      vim.api.nvim_win_set_cursor(winid, cursor)
      if not created then error(rendered) end
      rendered:render()
      active[#active + 1] = rendered
      return rendered
   end)
   if not ok then
      callback("Unable to render image: " .. tostring(result))
      return
   end
   callback(nil, result)
end

function M.close()
   for _, image in ipairs(active) do
      pcall(image.clear, image)
   end
   active = {}
end

return M

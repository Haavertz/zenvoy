local M = { count = 0, failures = {} }

function M.test(name, callback)
   M.count = M.count + 1
   local ok, err = pcall(callback)
   if not ok then
      M.failures[#M.failures + 1] = name .. ": " .. tostring(err)
   end
end

function M.equal(expected, actual)
   assert(vim.deep_equal(expected, actual),
      "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function normal_map(bufnr, lhs)
   for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if map.lhs == lhs then return map.callback end
   end
   error("missing dialog mapping " .. lhs)
end

---The open Zenvoy dialog as shown: its lines, button labels and the focused choice.
function M.dialog()
   for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "zenvoy-dialog" then
         local winid = vim.fn.bufwinid(bufnr)
         local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
         local row, col = unpack(vim.api.nvim_win_get_cursor(winid))
         local labels = {}
         for label in lines[#lines]:gmatch("%[ (.-) %]") do labels[#labels + 1] = label end
         return {
            bufnr = bufnr, winid = winid, lines = lines, text = table.concat(lines, "\n"), labels = labels,
            focus = lines[row]:match("^› (.*)$") or lines[row]:sub(col + 1):match("^(.-) %]"),
            press = function(lhs) normal_map(bufnr, lhs)() end,
         }
      end
   end
end

---Choose `label` in the open dialog the way a user does: Tab to it, then Enter.
function M.answer(label)
   local dialog = assert(M.dialog(), "expected an open dialog to answer " .. label)
   local seen = {}
   while dialog.focus ~= label do
      assert(dialog.focus and not seen[dialog.focus], "the dialog has no choice " .. label .. ":\n" .. dialog.text)
      seen[dialog.focus] = true
      dialog.press("<Tab>")
      dialog = M.dialog()
   end
   dialog.press("<CR>")
end

function M.finish(name)
   assert(#M.failures == 0, table.concat(M.failures, "\n"))
   print(("%s: %d tests passed"):format(name, M.count))
end

return M

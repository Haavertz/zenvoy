local M = {}

---@param bufnr integer
---@param mailboxes table[]
function M.render(bufnr, mailboxes)
   if not vim.api.nvim_buf_is_valid(bufnr) then
      return
   end

   local ids = {}

   for _, mailbox in ipairs(mailboxes or {}) do
      if type(mailbox) == "table" and type(mailbox.id) == "string" then
         table.insert(ids, mailbox.id)
      end
   end

   vim.bo[bufnr].modifiable = true
   vim.bo[bufnr].readonly = false

   local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, ids)

   vim.bo[bufnr].modifiable = false
   vim.bo[bufnr].readonly = true

   if not ok then
      error(err)
   end
end

return M

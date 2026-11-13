-- Default highlight groups. They are links or attributes with `default = true`, so
-- colorschemes and users can override any of them.
local M = {}

local groups = {
   ZenvoyLabel = { link = "Title" },
   ZenvoyMuted = { link = "Comment" },
   ZenvoySubject = { bold = true },
   ZenvoySeparator = { link = "FloatBorder" },
   ZenvoyHeading = { link = "Title" },
   ZenvoyBold = { bold = true },
   ZenvoyItalic = { italic = true },
   ZenvoyUnderline = { underline = true },
   ZenvoyStrike = { strikethrough = true },
   ZenvoyCode = { link = "String" },
   ZenvoyLink = { link = "Underlined" },
   ZenvoyQuote = { link = "Comment" },
   ZenvoySignature = { link = "Comment" },
   ZenvoyImage = { link = "Special" },
   ZenvoyAttachment = { link = "Directory" },
   ZenvoyError = { link = "DiagnosticError" },
}

local augroup

function M.setup()
   for name, spec in pairs(groups) do
      vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
   end
   if not augroup then
      augroup = vim.api.nvim_create_augroup("ZenvoyHighlights", { clear = true })
      -- `:colorscheme` clears all groups; restore the defaults afterwards.
      vim.api.nvim_create_autocmd("ColorScheme", { group = augroup, callback = M.setup })
   end
end

return M

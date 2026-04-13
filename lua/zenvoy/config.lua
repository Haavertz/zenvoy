local M = {}

M.config = {
  icons_enable = true,
}

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    -- print(M.config.icons_enable)
end

return M

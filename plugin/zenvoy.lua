vim.api.nvim_create_user_command("Zenvoy", function()
	require("zenvoy").open()
end, {} )

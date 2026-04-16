local state = require("zenvoy.states")

vim.api.nvim_create_user_command(state.command, function()
	require("zenvoy").open()
end, { desc = "Zenvoy Open" } )



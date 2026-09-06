<div align="center">
  <h1>📫 Zenvoy</h1>
  <p>This Zenvoy is TUI for email.</p>
</div>

### About 

A minimal email TUI for people who live in Neovim. Zenvoy is written entirely in
Lua and calls the Himalaya CLI asynchronously.

### Requirements

- [Neovim](https://neovim.io/doc/install/) >= v0.10.0
- [Himalaya](https://github.com/pimalaya/himalaya) >= v2.1.0, with a default account configured
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)

### Install 

Install the plugin with your preferred plugin manager. For example, with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
    "Haavertz/zenvoy",
    dependencies = {
        "MunifTanjim/nui.nvim",
    },
    opts = {},
}
```

or Nvim >= 0.12.0

```lua
vim.pack.add({
  { src = 'https://github.com/MunifTanjim/nui.nvim' },
  { src = 'https://github.com/Haavertz/zenvoy' },
})
require("zenvoy").setup()
```

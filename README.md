<div align="center">
  <h1>📫 Zenvoy</h1>
  <p>This Zenvoy is TUI for email.</p>
</div>

### About 

A minimal terminal email client for people who live in Neovim.

### Requirements

- [Neovim](https://neovim.io/doc/install/) >= v0.10.0
- [Himalaya](https://github.com/pimalaya/himalaya) >= v1.2.0
- [Nui](https://github.com/pimalaya/himalaya) >= 0.4.0

### Install 

Install the plugins with your prefered plugin manager. For example, with [Lazy-Nvim](https://github.com/rtgiskard/lazyNvim)
``` 
return {
    "Haavertz/zenvoy",
    depedences = {
        "MunifTanjim/nui.nvim",
    },
    opts = {},
}
```

or Nvim >= 0.12.0

```
vim.pack.add({
  { src = 'MunifTanjim/nui.nvim' },
  { src = 'Haavertz/zenvoy' },
})
```

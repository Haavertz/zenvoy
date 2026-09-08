<div align="center">
  <h1>📫 Zenvoy</h1>
  <p>This Zenvoy is TUI for email.</p>
  <![]('./specs/')
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

### Usage

Open the interface with `:Zenvoy`. Himalaya's configured default account and inbox
are used when it starts.

| Key | Action |
| --- | --- |
| `c` | Compose a new message |
| `r` / `R` | Reply / reply-all to the selected or opened email |
| `s` | Focus the mailbox sidebar |
| `j` / `k` in the sidebar | Select a mailbox and load its emails |
| `Enter` in the sidebar | Focus the email list; retry a failed mailbox load |
| `Enter` on an email | Read it and mark it as seen |
| `q` | Return from the message pane, then close Zenvoy |

The floating composer has **To, Cc, Bcc, Subject, and Body** fields. Use `Tab` or
`Shift-Tab` to move between them in normal or insert mode. Enter multiple
recipients separated by commas. New messages start in To; replies start above
the editable quoted original in Body.

Press `Ctrl-s` to confirm sending. Cancel keeps the draft open; a failed send
also keeps its text for a manual retry. `Escape` leaves insert mode normally.
In normal mode, `Escape` or `q` closes the composer and asks before discarding
changed text. A draft is held in memory only, and reopening the composer focuses
the existing draft.

Mailbox changes load the first page after a 150 ms pause, using the configured
page size (50 by default). Loading and sending activity appears at the bottom
of the sidebar. Replies preserve the email thread, prefer Reply-To, and exclude
your own address from reply-all. The configured Himalaya signature is appended
once when the final message is built.

Composition currently supports plain text. Attachments, persistent drafts,
account switching, and automatically archiving a copy in Sent are not provided.
An already-started send continues if the interface is closed externally; its
result is reported when the process finishes.

Default main-view shortcuts can be changed or disabled:

```lua
require("zenvoy").setup({
  himalaya = { page_size = 50 },
  keymaps = {
    ["s"] = false,
    ["gs"] = "focus_sidebar",
    ["c"] = "compose",
    ["r"] = "reply",
    ["R"] = "reply_all",
  },
})
```

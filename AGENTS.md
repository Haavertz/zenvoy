# Project notes

- Zenvoy is a Lua email client for Neovim. Keep message reading usable as plain text.
- Image rendering is optional and uses `image.nvim`; retain readable image markers when it is unavailable.
- Never download remote email images without explicit user consent. Restrict downloads to HTTP(S) and enforce the cache size limit.

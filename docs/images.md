# Images

[← Back to the README](../README.md)

In formatted emails, image markers such as `[Image: Logo]` appear where the image
is placed; in the plain-text view they are listed at the end of the body. Press
`I` (or `Enter`) on a marker to render it. Inline images are read from the
message; remote images ask before download. Rendering requires the optional
[image.nvim](https://github.com/3rd/image.nvim) plugin and a compatible terminal
backend (Kitty graphics, Sixel, or Überzug++). If rendering is unavailable, the
message text and image marker remain readable.

With lazy.nvim, install the renderer as an optional plugin and choose the backend
your terminal supports:

```lua
{
    "3rd/image.nvim",
    opts = {
        backend = "kitty",
        max_width_window_percentage = 80,
        max_height_window_percentage = 50,
    },
}
```

See [image.nvim's setup guide](https://github.com/3rd/image.nvim) for the
terminal and image-processing requirements for each backend. Remote images
also require `curl`.

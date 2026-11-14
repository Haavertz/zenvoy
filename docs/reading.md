# Reading

[← Back to the README](../README.md)

An email opens below the list. Press `z` to show it over the whole Zenvoy
window, where the bottom border shows **Loading email** while it loads, and `z`
again (or `s`) to bring back the folders and the list. The next email opens
below the list again, and `q` returns to the list on the email that was open. In the
message pane `z` acts at once, so Vim's `z` commands (`zo`, `zz`) are not
available there.

Messages open with a header block (From, To, Cc, Reply-To when it differs,
Date and Subject) followed by the body. HTML email is laid out like webmail, as
plain text in the buffer: headings, bold and italic text, lists, quotes with a
bar, aligned data tables and underlined links. Layout tables are flattened,
and hidden preheaders, styles, scripts and tracking pixels are left out. A rule
across the pane separates the header from the body, and the body from the
attachments. Long quoted replies are folded; press `Enter` on one to read it,
and `Enter` on quoted text to fold it again.

Links are opened only on request. The bottom border shows the destination of
the link under the cursor, `Enter` shows it again with **Open link** and
**Copy link**, and `gx` opens it directly. Terminals with OSC 8 support can also
click the underlined text. Only `http`, `https` and `mailto` links are opened.

Attachments are listed at the end with their type and size. `Enter` on one
offers **Open**, **Save** and **Save to…**; `S` saves it right away to
`attachments.download_dir`, or to Himalaya's `downloads-dir` when unset. Open
uses a private temporary copy that Neovim removes on exit, and asks again
before opening file types that can run code. File names that hide their real
extension with direction-control characters are shown without them.

`T` shows the text/plain alternative instead. Set `reader.prefer = "plain"` to
make it the default.

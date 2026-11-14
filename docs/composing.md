# Composing

[← Back to the README](../README.md)

The composer covers the Zenvoy window like a webmail compose page: **To, Cc,
Bcc and Subject** on one labeled line each, the message below them, and the
attached **Files** at the bottom. Use `Tab` or `Shift-Tab` to move between the
fields in normal or insert mode; the label of the current one is highlighted.
Enter multiple recipients separated by commas. New messages start in To; replies
start above the editable quoted original in the message, after an
"On <date>, <sender> wrote:" line.

To attach files, press `Ctrl-a` in any field and choose a file with path
completion, or type, paste or complete (`Ctrl-x Ctrl-f`) one path per line in
Files. `~`, `$VARIABLES`, quoted paths and `file://` URLs are accepted.
Each line shows the file size, or why it cannot be attached. Delete a line to
remove the file. Attachments work the same way in new messages, replies and
forwards.

Forwarding (`f`) downloads the original attachments to a private temporary
directory and lists them in Files, so you can remove any of them before
sending. The original headers and text follow two empty lines left for your note.

Press `Ctrl-s`, then choose **Send** in the dialog; it states how many files
and how many bytes are attached, and the bottom border shows **Sending…** until
Himalaya finishes. Cancel keeps the draft open; a failed send also
keeps its text for a manual retry. `Escape` leaves insert mode normally. In
normal mode, `Escape` or `q` closes the composer and asks before discarding
changed text. A draft is held in memory only, and reopening the composer focuses
the existing draft.

Mailbox changes load the first page after a 150 ms pause, using the configured
page size (40 by default). The list's title shows the page, such as
**Emails (40) · Page 2**. The shown page stays until the next one arrives, and
an open email stays open. Loading, downloading and sending activity appears at
the bottom of the sidebar. Replies preserve the email thread, prefer Reply-To,
and exclude your own address from reply-all. The configured Himalaya signature
is appended once when the final message is built. Messages with attachments get
a longer delivery timeout (5 minutes), so a slow upload is not reported as a
failure that invites a duplicate send.

The message body is plain text. Persistent drafts, account switching, and
automatically archiving a copy in Sent are not provided. An already-started send
continues if the interface is closed externally; its result is reported when the
process finishes. Reading an email with very large attachments is slower,
because Himalaya returns their decoded content with the message.

Attachments use `himalaya message compose --attach` and
`himalaya attachment download`, tested with Himalaya 2.2.

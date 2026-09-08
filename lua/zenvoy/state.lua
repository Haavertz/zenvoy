local M = {}

-- state default

M.current_account = ""
-- nil delegates to Himalaya's configured inbox alias until a mailbox is selected.
M.current_folder = nil
M.current_page = 1
M.mailboxes = {}
M.envelopes = {}
M.current_envelope_count = 0
M.is_open = false
M.email_visible = false
M.layout = nil
M.sidebar_popup = nil
M.listing_popup = nil
M.email_popup = nil
M.open_envelope = nil

return M

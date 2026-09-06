local M = {}

-- state default

M.current_account = ""
M.current_folder = "INBOX"
M.current_page = 1
M.mailboxes = {}
M.is_open = false
M.email_visible = false
M.layout = nil
M.sidebar_popup = nil
M.listing_popup = nil
M.email_popup = nil

return M

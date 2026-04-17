local M = {}

-- state default
M.current_account = ""
M.current_folder = "INBOX"
M.current_page = 1
M.current_envelope_page = 0
M.sidebar = nil
M.sidebar_popup = nil
M.sidebar_search = "right"
M.sidebar_navigation = "left"
M.sidebar_email = "right"
M.is_open = false
M.emails_list = {}
M.command = "Zenvoy"

return M


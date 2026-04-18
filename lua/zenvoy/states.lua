local M = {}

-- state default
M.current_account = ""
M.current_folder = "INBOX"
M.current_page = 1
M.current_envelope_page = 0
M.aside = 15 -- 0 to 100 (%)
M.sidebar_popup = nil
M.aside_search = 10
M.sidebar_navigation = "left"
M.sidebar_email = "right"
M.is_open = false
M.emails_list = {}
M.command = "Zenvoy"

return M


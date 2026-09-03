local M = {}

-- state default
M.current_account = ""
M.current_folder = "INBOX"
M.current_page = 1
M.current_envelope_page = 0
M.layout = nil
M.sidebar = nil
M.sidebar_popup = nil
M.main = nil
M.main_popup = nil
M.email = nil
M.email_popup = nil
M.is_open = false
M.email_visible = true
M.folder_list = {}

return M

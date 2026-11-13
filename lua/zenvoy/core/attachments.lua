-- Pure helpers for files attached to outgoing mail and for presenting received attachments.
local M = {}
local uv = vim.uv or vim.loop

-- File types that can run code when handed to the desktop's default application.
local executable = {}
for _, extension in ipairs({
   "app", "appimage", "bash", "bat", "bin", "cmd", "com", "command", "cpl", "csh", "deb", "desktop",
   "dmg", "exe", "fish", "hta", "jar", "js", "jse", "ksh", "lnk", "msc", "msi", "msp", "pif", "pkg",
   "pl", "ps1", "psm1", "py", "pyw", "rb", "reg", "rpm", "run", "scr", "sh", "url", "vb", "vbe",
   "vbs", "ws", "wsf", "wsh", "zsh",
}) do executable[extension] = true end

local function is_absolute(path)
   return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil or path:sub(1, 2) == "\\\\"
end
M.is_absolute = is_absolute

---Remove characters that reorder or hide text, such as U+202E in "invoice‮fdp.exe".
---@param text string
---@return string
function M.strip_format_controls(text)
   return (text:gsub("\226\128[\139-\143\170-\174]", "") -- U+200B–U+200F, U+202A–U+202E
      :gsub("\226\129[\160\166-\169]", "") -- U+2060, U+2066–U+2069
      :gsub("\239\187\191", "") -- U+FEFF
      :gsub("\216\156", "")) -- U+061C
end

---A single-line, spoof-resistant label for an attachment or path supplied by an email.
---@param name any
---@param fallback? string
---@return string
function M.display_name(name, fallback)
   if type(name) ~= "string" then return fallback or "attachment" end
   local label = vim.trim(M.strip_format_controls(name):gsub("%c", " "))
   if label == "" then return fallback or "attachment" end
   return label
end

---@param bytes integer?
---@return string?
function M.format_size(bytes)
   if type(bytes) ~= "number" or bytes < 0 then return nil end
   if bytes < 1024 then return ("%d B"):format(bytes) end
   local units, value, index = { "KB", "MB", "GB", "TB" }, bytes / 1024, 1
   while value >= 1024 and index < #units do
      value, index = value / 1024, index + 1
   end
   local text = value >= 10 and ("%.0f"):format(value) or ("%.1f"):format(value):gsub("%.0$", "")
   return text .. " " .. units[index]
end

---Short type label: the file extension when present, otherwise the MIME subtype.
---@param name string?
---@param mime string?
---@return string
function M.kind(name, mime)
   local extension = type(name) == "string" and name:match("%.([%w]+)$")
   if extension and #extension <= 5 then return extension:upper() end
   local subtype = type(mime) == "string" and mime:match("^[%w.+-]+/([%w.+-]+)")
   if subtype then
      subtype = subtype:gsub("^x%-", ""):gsub("^vnd%.", "")
      return (#subtype <= 12 and subtype or subtype:sub(1, 11) .. "…"):upper()
   end
   return "FILE"
end

---@param name string?
---@return boolean
function M.is_executable(name)
   local extension = type(name) == "string" and name:match("%.([%w]+)$")
   if not extension then return false end
   return executable[extension:lower()] == true
end

---Resolve one attachment line typed, pasted or chosen by the user.
---Quotes and file:// URLs from drag-and-drop are accepted; `~` and `$VARS` are expanded
---without Vim's wildcard or `%` expansion.
---@param value string
---@return { path: string, name: string, size: integer }? file Nil for a blank line or an error.
---@return string? error
function M.resolve(value)
   if type(value) ~= "string" then return nil, "Invalid attachment path" end
   local path = vim.trim(value)
   if path == "" then return nil end
   if path:find("%c") then return nil, "Attachment paths must be single lines" end
   local first = path:sub(1, 1)
   if #path >= 2 and (first == '"' or first == "'") and path:sub(-1) == first then path = path:sub(2, -2) end
   if path:match("^file://") then
      local ok, decoded = pcall(vim.uri_to_fname, path)
      if not ok then return nil, "Invalid attachment URL: " .. path end
      path = decoded
   end
   path = vim.fs.normalize(path)
   if not is_absolute(path) then path = vim.fs.normalize(vim.fn.getcwd() .. "/" .. path) end
   local stat = uv.fs_stat(path)
   if not stat then return nil, "Attachment not found: " .. path end
   if stat.type ~= "file" then return nil, "Attachment is not a file: " .. path end
   if not uv.fs_access(path, "R") then return nil, "Attachment is not readable: " .. path end
   return { path = path, name = vim.fs.basename(path), size = stat.size }
end

---Resolve every non-blank line, keeping the first occurrence of each file.
---@param lines string[]
---@return { path: string, name: string, size: integer }[]? files
---@return string? error The first invalid line.
function M.parse(lines)
   local files, seen = {}, {}
   for _, line in ipairs(lines or {}) do
      local file, err = M.resolve(line)
      if err then return nil, err end
      if file and not seen[file.path] then
         seen[file.path] = true
         files[#files + 1] = file
      end
   end
   return files
end

---@param files { size?: integer }[]
---@return integer
function M.total_size(files)
   local total = 0
   for _, file in ipairs(files or {}) do total = total + (tonumber(file.size) or 0) end
   return total
end

return M

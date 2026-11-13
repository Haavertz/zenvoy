local defaults = {
   himalaya = {
      executable = "himalaya",
      timeout = 30000,
      page_size = 50,
   },
   sidebar = {
      width = 30,
   },
   reader = {
      -- "html" shows the formatted HTML part like webmail; "plain" prefers text/plain.
      prefer = "html",
      -- Maximum text width for formatted HTML; 0 uses the whole message pane.
      max_width = 100,
      -- Collapse long quoted replies; Enter opens them.
      fold_quotes = true,
   },
   attachments = {
      -- Where S/Save stores attachments; nil uses Himalaya's downloads-dir.
      download_dir = nil,
   },
   wrap_folder_navigation = false,
   icons_enable = false,
   keymaps = {
      ["q"] = "close_or_back",
      ["c"] = "compose",
      ["r"] = "reply",
      ["R"] = "reply_all",
      ["f"] = "forward",
      ["s"] = "focus_sidebar",
      ["I"] = "show_image",
      ["gx"] = "open_link",
      ["S"] = "save_attachment",
      ["T"] = "toggle_view",
      ["<Tab>"] = "next_item",
      ["<S-Tab>"] = "previous_item",
      ["z"] = "toggle_fullscreen",
      ["?"] = "help",
      ["<CR>"] = "enter",
   },
}

local M = {
   config = vim.deepcopy(defaults),
}

function M.setup(opts)
   local options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
   local himalaya = options.himalaya
   assert(type(himalaya) == "table", "himalaya must be a table")
   assert(type(himalaya.executable) == "string" and himalaya.executable:find("%S"),
      "himalaya.executable must be a non-empty string")
   for _, name in ipairs({ "timeout", "page_size" }) do
      local value = himalaya[name]
      assert(type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0,
         "himalaya." .. name .. " must be a positive integer")
   end
   local reader = options.reader
   assert(type(reader) == "table", "reader must be a table")
   assert(reader.prefer == "html" or reader.prefer == "plain", 'reader.prefer must be "html" or "plain"')
   assert(type(reader.max_width) == "number" and reader.max_width >= 0 and reader.max_width % 1 == 0,
      "reader.max_width must be a non-negative integer")
   assert(type(reader.fold_quotes) == "boolean", "reader.fold_quotes must be a boolean")
   local download_dir = type(options.attachments) == "table" and options.attachments.download_dir
   assert(type(options.attachments) == "table" and (download_dir == nil
      or (type(download_dir) == "string" and download_dir:find("%S"))),
      "attachments.download_dir must be nil or a non-empty path")
   if download_dir then options.attachments.download_dir = vim.fs.normalize(download_dir) end
   M.config = options
end

function M.get()
   return M.config
end

return M

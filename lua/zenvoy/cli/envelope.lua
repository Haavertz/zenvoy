local cli = require("himalaya.cli")
local M = {}


function M.list(opts, callback)
   opts = opts or {}

   local args = { "--output json", "envelope list" }

   if opts.folder then 
      table.insert(args, "--folder")
      table.insert(args, vim.fn.shellescape(opts.folder))
   end
end

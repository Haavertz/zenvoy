local M = { count = 0, failures = {} }

function M.test(name, callback)
   M.count = M.count + 1
   local ok, err = pcall(callback)
   if not ok then
      M.failures[#M.failures + 1] = name .. ": " .. tostring(err)
   end
end

function M.equal(expected, actual)
   assert(vim.deep_equal(expected, actual),
      "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

function M.finish(name)
   assert(#M.failures == 0, table.concat(M.failures, "\n"))
   print(("%s: %d tests passed"):format(name, M.count))
end

return M

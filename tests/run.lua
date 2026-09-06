-- Run each suite in a fresh Neovim instance so mocks cannot leak between suites.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
if vim.env.NUI_NVIM_PATH then vim.opt.runtimepath:prepend(vim.env.NUI_NVIM_PATH) end
assert(pcall(require, "nui.popup"), "Add nui.nvim to runtimepath or set NUI_NVIM_PATH to its checkout")

local specs = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
table.sort(specs)
local failures = 0
for _, spec in ipairs(specs) do
   local result = vim.system({
      vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n",
      "--cmd", "lua vim.opt.runtimepath = " .. string.format("%q", vim.o.runtimepath),
      "-l", spec,
   }, { cwd = root, text = true, timeout = 10000 }):wait()
   local output = vim.trim((result.stdout or "") .. (result.stderr or ""))
   if output ~= "" then print(output) end
   if result.code ~= 0 then
      failures = failures + 1
      print(("FAIL %s (exit %d)"):format(vim.fn.fnamemodify(spec, ":t"), result.code))
   end
end

assert(failures == 0, ("%d of %d suites failed"):format(failures, #specs))
print(("All %d suites passed"):format(#specs))

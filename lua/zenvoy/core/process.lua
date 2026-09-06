local M = {}

local function project_root()
   local source = debug.getinfo(1, "S").source:gsub("^@", "")
   return vim.fs.root(source, "go.mod")
end

local function handle_result(result, callbacks)
   local on_error = callbacks.on_error or function(message)
      vim.notify("Zenvoy: " .. message, vim.log.levels.ERROR)
   end

   if result.code ~= 0 then
      local message = vim.trim(result.stderr or "")

      if message == "" then
         message = vim.trim(result.stdout or "")
      end

      if message == "" then
         message = string.format("Himalaya process exited with code %d", result.code)
      end

      on_error(message)
      return
   end

   local output = vim.trim(result.stdout or "")
   local ok, response = pcall(vim.json.decode, output)

   if not ok then
      on_error("Invalid Zenvoy JSON: " .. response)
      return
   end

   if type(response) ~= "table" or type(response.mailboxes) ~= "table" then
      on_error("Invalid Zenvoy JSON: missing mailboxes array")
      return
   end

   if type(response.envelopes) ~= "table" then
      on_error("Invalid Zenvoy JSON: missing envelopes array")
      return
   end

   if callbacks.on_success then
      callbacks.on_success(response)
   end
end

---@param callbacks? { on_success?: fun(response: table), on_error?: fun(message: string) }
function M.run(callbacks)
   callbacks = callbacks or {}

   return vim.system(
      { "go", "run", "./cmd/zenvoy" },
      { cwd = project_root(), text = true },
      vim.schedule_wrap(function(result)
         handle_result(result, callbacks)
      end)
   )
end

return M

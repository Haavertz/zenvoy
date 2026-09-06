---@class ZenvoyRequest
---@field cancel fun(self: ZenvoyRequest)

---@class ZenvoyProcess
---@field system function
---@field schedule fun(callback: function)
---@field timeout integer
local Process = {}
Process.__index = Process

---@param options? { system?: function, schedule?: function, timeout?: integer }
---@return ZenvoyProcess
function Process.new(options)
   options = options or {}
   return setmetatable({
      system = options.system or vim.system,
      schedule = options.schedule or vim.schedule,
      timeout = options.timeout or 30000,
   }, Process)
end

local function failure_message(result, timeout)
   if result.code == 124 then
      return ("Process timed out after %d ms"):format(timeout)
   end

   local details = vim.trim(result.stderr or "")
   if details == "" then details = vim.trim(result.stdout or "") end
   if details ~= "" then return details end

   if result.signal and result.signal ~= 0 then
      return ("Process terminated by signal %d"):format(result.signal)
   end
   return ("Process exited with code %d"):format(result.code)
end

---Run argv directly. Callbacks always run on Neovim's main loop, including spawn errors.
---@param command string[]
---@param callback fun(err: string?, output: string?)
---@return ZenvoyRequest
function Process:run(command, callback)
   local finished, cancelled = false, false
   local job
   local request = {}

   function request:cancel()
      if finished or cancelled then return end
      cancelled = true
      -- The process may have exited while its callback is still queued.
      if job then pcall(job.kill, job, 15) end
   end

   local function on_exit(result)
      self.schedule(function()
         if finished or cancelled then return end
         finished = true
         if result.code ~= 0 or (result.signal and result.signal ~= 0) then
            callback(failure_message(result, self.timeout))
         else
            callback(nil, result.stdout or "")
         end
      end)
   end

   local ok, result = pcall(self.system, command, { text = true, timeout = self.timeout }, on_exit)
   if ok then
      job = result
   else
      on_exit({ code = -1, stderr = tostring(result) })
   end
   return request
end

return Process

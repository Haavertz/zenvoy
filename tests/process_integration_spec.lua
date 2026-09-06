vim.opt.runtimepath:prepend(vim.fn.getcwd())

local t = dofile("tests/helpers.lua")
local Process = require("zenvoy.core.process")

local function child(code)
   return { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "--cmd", "lua " .. code }
end

local function run(command, options)
   local result
   Process.new(options):run(command, function(err, output)
      assert(not vim.in_fast_event(), "callbacks must be safe to use Neovim APIs")
      result = { err = err, output = output }
   end)
   assert(vim.wait(3000, function() return result ~= nil end, 5), "child process did not finish")
   return result
end

t.test("captures actual child stdout", function()
   local result = run(child([[io.stdout:write('{"mailboxes":[]}'); vim.cmd('qa!')]]))
   t.equal({ output = '{"mailboxes":[]}' }, result)
end)

t.test("reports actual child stderr and exit failure", function()
   local result = run(child([[io.stderr:write('fixture failure'); vim.cmd('cquit 7')]]))
   assert(result.err:find("fixture failure", 1, true), result.err)
   t.equal(nil, result.output)
end)

t.test("terminates a real process on timeout", function()
   local result = run(child([[vim.wait(10000, function() return false end); vim.cmd('qa!')]]), { timeout = 50 })
   t.equal("Process timed out after 50 ms", result.err)
end)

t.test("cancels a real child without delivering a callback", function()
   local job, called
   local process = Process.new({ system = function(...)
      job = vim.system(...)
      return job
   end })
   local request = process:run(child([[vim.wait(10000, function() return false end); vim.cmd('qa!')]]),
      function() called = true end)
   request:cancel()
   assert(vim.wait(3000, function() return job:is_closing() end, 5), "cancel must terminate the child")
   vim.wait(30, function() return false end, 5)
   t.equal(nil, called)
end)

t.test("reports a missing executable without throwing", function()
   local result = run({ vim.fn.tempname() .. "-missing-executable" })
   assert(type(result.err) == "string" and result.err ~= "")
   t.equal(nil, result.output)
end)

t.finish("process_integration_spec")

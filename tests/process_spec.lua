vim.opt.runtimepath:prepend(vim.fn.getcwd())

local t = dofile("tests/helpers.lua")
local Process = require("zenvoy.core.process")

local function fixture(options)
   local captured = { scheduled = {}, kills = {}, calls = {} }
   options = options or {}
   options.system = options.system or function(command, opts, on_exit)
      captured.command, captured.options, captured.exit = command, opts, on_exit
      return { kill = function(_, signal) captured.kills[#captured.kills + 1] = signal end }
   end
   options.schedule = function(callback) captured.scheduled[#captured.scheduled + 1] = callback end
   local process = Process.new(options)
   local request = process:run({ "himalaya", "mailbox", "list", "--json" }, function(err, output)
      captured.calls[#captured.calls + 1] = { err = err, output = output }
   end)
   function captured.flush()
      for _, callback in ipairs(captured.scheduled) do callback() end
      captured.scheduled = {}
   end
   return captured, request
end

t.test("passes argv without a shell, captures text, and enforces the default timeout", function()
   local result = fixture()
   t.equal({ "himalaya", "mailbox", "list", "--json" }, result.command)
   t.equal({ text = true, timeout = 30000 }, result.options)
   result.exit({ code = 0, stdout = "raw output\n", stderr = "" })
   t.equal({}, result.calls)
   result.flush()
   t.equal({ { output = "raw output\n" } }, result.calls)
end)

t.test("uses each instance's timeout", function()
   local first, second = fixture({ timeout = 10 }), fixture({ timeout = 20 })
   t.equal(10, first.options.timeout)
   t.equal(20, second.options.timeout)
end)

t.test("reports stderr, stdout fallback, and exit status", function()
   for _, example in ipairs({
      { code = 1, stderr = "  authentication failed\n", stdout = "ignored", expected = "authentication failed" },
      { code = 2, stderr = " ", stdout = "JSON error", expected = "JSON error" },
      { code = 3, expected = "Process exited with code 3" },
      { code = 124, expected = "Process timed out after 30000 ms" },
      { code = 0, signal = 15, expected = "Process terminated by signal 15" },
   }) do
      local result = fixture()
      result.exit(example)
      result.flush()
      t.equal({ { err = example.expected } }, result.calls)
   end
end)

t.test("delivers spawn failures asynchronously through the error callback", function()
   local result = fixture({ system = function() error("executable missing") end })
   t.equal({}, result.calls)
   result.flush()
   assert(result.calls[1].err:find("executable missing", 1, true))
end)

t.test("cancel is idempotent and suppresses an already queued result", function()
   local result, request = fixture()
   result.exit({ code = 0, stdout = "late" })
   request:cancel()
   request:cancel()
   result.flush()
   t.equal({ 15 }, result.kills)
   t.equal({}, result.calls)
end)

t.test("completion is delivered once and cancellation after completion does nothing", function()
   local result, request = fixture()
   result.exit({ code = 0, stdout = "first" })
   result.exit({ code = 1, stderr = "duplicate" })
   result.flush()
   request:cancel()
   t.equal({ { output = "first" } }, result.calls)
   t.equal({}, result.kills)
end)

t.finish("process_spec")

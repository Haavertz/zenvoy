vim.opt.runtimepath:prepend(vim.fn.getcwd())

local process = require("zenvoy.core.process")
local original_system = vim.system

local function run_process(result, callbacks)
   local captured = {}
   local exit_callback
   local expected_job = { mocked = true }
   local completed = false

   local on_success = callbacks.on_success
   local on_error = callbacks.on_error

   callbacks.on_success = function(response)
      completed = true
      if on_success then
         on_success(response)
      end
   end

   callbacks.on_error = function(message)
      completed = true
      if on_error then
         on_error(message)
      end
   end

   vim.system = function(command, options, on_exit)
      captured.command = command
      captured.options = options
      exit_callback = on_exit
      return expected_job
   end

   local job = process.run(callbacks)
   assert(job == expected_job, "process.run must return the vim.system job")

   exit_callback(result)
   assert(vim.wait(100, function()
      return completed
   end), "process callback did not complete")

   vim.system = original_system

   return captured
end

local success_response
local success_error
local success = run_process({
   code = 0,
   stdout = '{"mailboxes":[{"id":"Inbox"}],"envelopes":[{"id":"30222"}]}',
   stderr = "",
}, {
   on_success = function(response)
      success_response = response
   end,
   on_error = function(message)
      success_error = message
   end,
})

assert(vim.deep_equal(success.command, { "go", "run", "./cmd/zenvoy" }), vim.inspect(success.command))
assert(success.options.text == true, "vim.system must capture text output")
assert(success_error == nil, success_error)
assert(success_response.mailboxes[1].id == "Inbox", vim.inspect(success_response))
assert(success_response.envelopes[1].id == "30222", vim.inspect(success_response))

local process_error
local failed = run_process({
   code = 1,
   stdout = "",
   stderr = "Himalaya failed",
}, {
   on_error = function(message)
      process_error = message
   end,
})

assert(process_error == "Himalaya failed", process_error)

local decode_error
local invalid = run_process({
   code = 0,
   stdout = "not-json",
   stderr = "",
}, {
   on_error = function(message)
      decode_error = message
   end,
})

assert(decode_error and decode_error:find("Invalid Zenvoy JSON", 1, true), decode_error)

local schema_error
run_process({
   code = 0,
   stdout = '{"mailboxes":[]}',
   stderr = "",
}, {
   on_error = function(message)
      schema_error = message
   end,
})

assert(schema_error == "Invalid Zenvoy JSON: missing envelopes array", schema_error)

vim.system = original_system

print("process_spec: 4 tests passed")

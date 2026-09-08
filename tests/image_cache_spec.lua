vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local Cache = require("zenvoy.core.image_cache")
local root = vim.fn.tempname()
local png = "\137PNG\r\n\26\n" .. string.rep("a", 40)
local jobs = {}
local process = { run = function(_, command, callback)
   local job = { command = command, callback = callback, killed = false }
   function job:cancel() self.killed = true end
   jobs[#jobs + 1] = job
   return job
end }
local cache = Cache.new(process, { directory = root, max_bytes = 100 })
local function output(job)
   for i, arg in ipairs(job.command) do
      if arg == "--output" then return job.command[i + 1] end
   end
end
local function write(path, data)
   local fd = assert(vim.uv.fs_open(path, "w", 384))
   assert(vim.uv.fs_write(fd, data, 0))
   vim.uv.fs_close(fd)
end

t.test("creates no cache directory until an image is requested", function()
   t.equal(nil, vim.uv.fs_stat(root))
end)

t.test("saves embedded bytes privately under a safe generated name", function()
   local result, err
   local data = { png:byte(1, #png) }
   cache:load({ kind = "embedded", data = data, name = "../../unsafe.png" }, function(e, path) err, result = e, path end)
   t.equal(nil, err)
   assert(result:sub(1, #root + 1) == root .. "/")
   assert(not result:find("unsafe", 1, true))
   t.equal(384, bit.band(vim.uv.fs_stat(result).mode, 511))
   t.equal(0, #jobs)
end)

t.test("downloads only HTTP images with limits and reuses the completed cache", function()
   local image = { kind = "remote", url = "https://example.test/photo.png" }
   local result, err
   cache:load(image, function(e, path) err, result = e, path end)
   local job = jobs[#jobs]
   assert(vim.tbl_contains(job.command, "--max-filesize"))
   assert(vim.tbl_contains(job.command, "--proto"))
   t.equal(image.url, job.command[#job.command])
   write(output(job), png)
   job.callback(nil, "")
   t.equal(nil, err)
   assert(result and vim.uv.fs_stat(result))
   local count = #jobs
   cache:load(image, function(e, path) t.equal(nil, e); t.equal(result, path) end)
   t.equal(count, #jobs)
end)

t.test("cancelling removes partial downloads and suppresses late callbacks", function()
   local called = false
   local request = cache:load({ kind = "remote", url = "https://example.test/cancel.png" }, function() called = true end)
   local job = jobs[#jobs]
   request:cancel()
   t.equal(true, job.killed)
   t.equal(nil, vim.uv.fs_stat(output(job)))
   job.callback(nil, "")
   t.equal(false, called)
end)

t.test("rejects unsafe protocols, non-images and oversized content", function()
   for _, image in ipairs({
      { kind = "remote", url = "file:///etc/passwd" },
      { kind = "embedded", data = { 65, 66, 67 } },
      { kind = "embedded", data = { 999 } },
      { kind = "data", data = vim.base64.encode(png .. string.rep("a", 100)) },
   }) do
      local err
      cache:load(image, function(e) err = e end)
      assert(err, vim.inspect(image))
   end
end)

vim.fn.delete(root, "rf")
t.finish("image_cache_spec")

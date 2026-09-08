vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local Images = require("zenvoy.ui.images")
local function fixture()
   local calls, prompt, complete = {}, nil, nil
   local preview = { supported = function() return true end, close = function() end,
      open = function(_, path, _, callback) calls[#calls + 1] = "show:" .. path; callback() end }
   local controller = Images.new({
      preview = preview,
      choose = function(_, _, callback) prompt = callback end,
      load = function(_, callback)
         calls[#calls + 1] = "download"
         complete = callback
         return { cancel = function() calls[#calls + 1] = "cancel" end }
      end,
      activity = function(label)
         t.equal("Loading image", label)
         calls[#calls + 1] = "loading"
         return function() calls[#calls + 1] = "finished" end
      end,
      notify = function() calls[#calls + 1] = "error" end,
   })
   return controller, calls, function(answer) prompt(answer) end, function(...) complete(...) end
end
local image = { kind = "remote", name = "Photo", url = "https://example.test/photo.png" }

t.test("clicking asks first and declining does not download", function()
   local controller, calls, answer = fixture()
   controller:activate(image)
   t.equal({}, calls)
   answer("Cancel")
   t.equal({}, calls)
end)

t.test("approval downloads, shows the cached path and releases sidebar activity", function()
   local controller, calls, answer, complete = fixture()
   controller:activate(image)
   answer("Show image")
   t.equal({ "loading", "download" }, calls)
   complete(nil, "/tmp/cached-image")
   t.equal({ "loading", "download", "show:/tmp/cached-image", "finished" }, calls)
end)

t.test("changing messages invalidates a pending approval", function()
   local controller, calls, answer = fixture()
   controller:activate(image)
   controller:clear()
   answer("Show image")
   t.equal({}, calls)
end)

t.test("closing cancels pending downloads and late results cannot display", function()
   local controller, calls, answer, complete = fixture()
   controller:activate(image)
   answer("Show image")
   controller:clear()
   complete(nil, "/tmp/stale")
   t.equal({ "loading", "download", "cancel", "finished" }, calls)
end)

t.finish("image_consent_spec")

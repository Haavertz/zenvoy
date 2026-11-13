vim.opt.runtimepath:prepend(vim.fn.getcwd())

local t = dofile("tests/helpers.lua")
local config = require("zenvoy.config")

t.test("provides Himalaya defaults and resets user options on setup", function()
   t.equal({ executable = "himalaya", timeout = 30000, page_size = 40 }, config.get().himalaya)
   config.setup({ himalaya = { executable = "/custom/himalaya", page_size = 10 } })
   t.equal({ executable = "/custom/himalaya", timeout = 30000, page_size = 10 }, config.get().himalaya)
   config.setup()
   t.equal("himalaya", config.get().himalaya.executable)
end)

t.test("provides reader and attachment defaults with validation", function()
   config.setup()
   t.equal({ prefer = "html", max_width = 100, fold_quotes = true }, config.get().reader)
   t.equal(nil, config.get().attachments.download_dir)
   config.setup({ reader = { prefer = "plain", max_width = 0 }, attachments = { download_dir = "~/Mail files" } })
   t.equal("plain", config.get().reader.prefer)
   t.equal(0, config.get().reader.max_width)
   t.equal(vim.fs.normalize("~/Mail files"), config.get().attachments.download_dir)
   for _, options in ipairs({
      { reader = { prefer = "rich" } }, { reader = { max_width = -1 } }, { reader = { max_width = 1.5 } },
      { reader = { fold_quotes = "yes" } }, { attachments = { download_dir = "" } },
      { attachments = { download_dir = 1 } }, { reader = false }, { attachments = false },
   }) do
      local before = config.get()
      assert(not pcall(config.setup, options), vim.inspect(options))
      assert(config.get() == before, "invalid setup must preserve the last valid options")
   end
   config.setup()
end)

t.test("rejects invalid backend options without replacing the current configuration", function()
   for _, options in ipairs({
      { himalaya = false }, { himalaya = { executable = "" } }, { himalaya = { executable = 1 } },
      { himalaya = { timeout = 0 } }, { himalaya = { timeout = -1 } },
      { himalaya = { timeout = "30" } }, { himalaya = { page_size = 0 } },
      { himalaya = { page_size = 1.5 } },
   }) do
      local before = config.get()
      local ok, err = pcall(config.setup, options)
      assert(not ok and tostring(err):find("himalaya", 1, true), vim.inspect(options))
      assert(config.get() == before, "invalid setup must preserve the last valid options")
   end
end)

t.finish("config_spec")

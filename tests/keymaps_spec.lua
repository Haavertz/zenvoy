vim.opt.runtimepath:prepend(vim.fn.getcwd())

local failures = {}
local tests_run = 0

local function assert_equal(expected, actual, message)
   if expected ~= actual then
      error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
   end
end

local function test(name, callback)
   tests_run = tests_run + 1
   local ok, err = pcall(callback)

   if not ok then
      table.insert(failures, string.format("%s: %s", name, err))
   end
end

local function find_mapping(bufnr, lhs)
   for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if mapping.lhs == lhs then
         return mapping
      end
   end
end

test("keeps the existing Zenvoy keymap defaults", function()
   package.loaded["zenvoy.config"] = nil
   local config = require("zenvoy.config")
   local options = config.get()

   assert_equal(false, options.wrap_folder_navigation, "wrap_folder_navigation")
   assert_equal(false, options.icons_enable, "icons_enable")
   assert_equal("close_or_back", options.keymaps["q"], "q mapping")
   assert_equal(false, options.keymaps["c"], "c mapping")
   assert_equal(false, options.keymaps["r"], "r mapping")
   assert_equal("enter", options.keymaps["<CR>"], "enter mapping")
end)

test("resets defaults before merging new setup options", function()
   package.loaded["zenvoy.config"] = nil
   local config = require("zenvoy.config")

   config.setup({
      keymaps = {
         ["q"] = false,
         ["x"] = "close_or_back",
      },
   })

   assert_equal(false, config.get().keymaps["q"], "disabled mapping")
   assert_equal("close_or_back", config.get().keymaps["x"], "custom mapping")

   config.setup()

   assert_equal("close_or_back", config.get().keymaps["q"], "restored default mapping")
   assert_equal(nil, config.get().keymaps["x"], "removed previous custom mapping")
end)

test("installs an action as a buffer-local mapping", function()
   package.loaded["zenvoy.keymaps"] = nil
   local keymaps = require("zenvoy.keymaps")
   local target = vim.api.nvim_create_buf(false, true)
   local other = vim.api.nvim_create_buf(false, true)
   local calls = 0

   keymaps.apply(target, { ["x"] = "close_or_back" }, {
      close_or_back = function()
         calls = calls + 1
      end,
   })

   local mapping = find_mapping(target, "x")
   assert(mapping, "expected x to be mapped in the target buffer")
   assert_equal(nil, find_mapping(other, "x"), "mapping leaked to another buffer")
   assert_equal("Zenvoy: close or back", mapping.desc, "mapping description")

   mapping.callback()
   assert_equal(1, calls, "mapped callback execution")
end)

test("does not install disabled mappings", function()
   package.loaded["zenvoy.keymaps"] = nil
   local keymaps = require("zenvoy.keymaps")
   local bufnr = vim.api.nvim_create_buf(false, true)

   keymaps.apply(bufnr, { ["x"] = false }, {})

   assert_equal(nil, find_mapping(bufnr, "x"), "disabled mapping")
end)

test("rejects an unknown action with a useful error", function()
   package.loaded["zenvoy.keymaps"] = nil
   local keymaps = require("zenvoy.keymaps")
   local bufnr = vim.api.nvim_create_buf(false, true)
   local ok, err = pcall(keymaps.apply, bufnr, { ["x"] = "missing" }, {})

   assert_equal(false, ok, "unknown action should fail")
   assert(tostring(err):find("Unknown Zenvoy action: missing", 1, true), err)
end)

test("returns the configured keys for help text", function()
   package.loaded["zenvoy.keymaps"] = nil
   local keymaps = require("zenvoy.keymaps")
   local keys = keymaps.keys_for({
      ["q"] = "close_or_back",
      ["<Esc>"] = "close_or_back",
      ["x"] = false,
   }, "close_or_back")

   assert_equal("<Esc>", keys[1], "first sorted key")
   assert_equal("q", keys[2], "second sorted key")
   assert_equal(2, #keys, "number of configured keys")
end)

if #failures > 0 then
   error(table.concat(failures, "\n"))
end

print(string.format("keymaps_spec: %d tests passed", tests_run))

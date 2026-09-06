local M = {}

local function description(action_name)
   return "Zenvoy: " .. action_name:gsub("_", " ")
end

---@param mappings table<string, string|false>
---@param action_name string
---@return string[]
function M.keys_for(mappings, action_name)
   local keys = {}

   for lhs, configured_action in pairs(mappings) do
      if configured_action == action_name then
         table.insert(keys, lhs)
      end
   end

   table.sort(keys)

   return keys
end

---@param bufnr integer
---@param mappings table<string, string|false>
---@param actions table<string, function>
function M.apply(bufnr, mappings, actions)
   for lhs, action_name in pairs(mappings) do
      if action_name ~= false then
         local callback = actions[action_name]

         assert(callback, string.format("Unknown Zenvoy action: %s", action_name))

         vim.keymap.set("n", lhs, callback, {
            buffer = bufnr,
            desc = description(action_name),
            nowait = true,
            silent = true,
         })
      end
   end
end

return M

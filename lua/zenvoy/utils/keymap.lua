local M = {}

local function action_description(action_name)
   return action_name:gsub("_", " "):gsub("^%l", string.upper)
end

function M.apply(bufnr, keymap_config, actions)
   for key, mapping in pairs(keymap_config) do
      local action_name, callback, description, action_config

      if type(mapping) == "string" then
         if mapping == "none" then
            goto continue
         end

         action_name = mapping
         callback = actions[action_name]
         description = action_description(action_name)
      elseif type(mapping) == "table" then
         if type(mapping[1]) == "function" then
            callback = mapping[1]
            description = mapping.desc
         elseif type(mapping[1]) == "string" then
            if mapping[1] == "none" then
               goto continue
            end

            action_name = mapping[1]
            callback = actions[action_name]
            description = mapping.desc or action_description(action_name)
            action_config = mapping.config
         end
      elseif type(mapping) == "function" then
         callback = mapping
         description = "Custom action"
      end

      if not callback then
         goto continue
      end

      if action_config then
         local configured_callback = callback
         callback = function()
            configured_callback(action_config)
         end
      end

      vim.keymap.set("n", key, callback, {
         buffer = bufnr,
         desc = description,
         nowait = true,
         silent = true,
      })

      ::continue::
   end
end

return M

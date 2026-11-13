local Images = {}
Images.__index = Images

---@param options table
---@return table
function Images.new(options)
   return setmetatable({
      preview = options.preview,
      choose = options.choose,
      load = options.load,
      activity = options.activity,
      notify = options.notify,
      pending = {},
      generation = 0,
   }, Images)
end

function Images:_load(image, generation)
   local finish = self.activity("Loading image")
   local pending = { active = true, finish = finish }
   self.pending[pending] = true
   local ok, request = pcall(self.load, image, function(err, path)
      if not pending.active then return end
      pending.active = false
      self.pending[pending] = nil
      if generation ~= self.generation then
         finish()
         return
      end
      if err then
         self.notify("Zenvoy: " .. err, vim.log.levels.ERROR)
         finish()
         return
      end
      local shown, preview_error = pcall(self.preview.open, self.preview, path, image, function(render_error)
         if generation ~= self.generation then return end
         if render_error then self.notify("Zenvoy: " .. render_error, vim.log.levels.ERROR) end
         finish()
      end)
      if not shown then
         self.notify("Zenvoy: Unable to render image: " .. tostring(preview_error), vim.log.levels.ERROR)
         finish()
      end
   end)
   if not ok then
      pending.active = false
      self.pending[pending] = nil
      self.notify("Zenvoy: Unable to load image: " .. tostring(request), vim.log.levels.ERROR)
      finish()
      return
   end
   if pending.active then pending.request = request end
end

---@param image table
function Images:activate(image)
   local ok, supported = pcall(self.preview.supported)
   if not ok or not supported then
      self.notify("Zenvoy: image.nvim and a supported terminal backend are required to render images",
         vim.log.levels.INFO)
      return
   end
   local generation = self.generation
   local function load()
      if generation == self.generation then self:_load(image, generation) end
   end
   if image.kind ~= "remote" then
      load()
      return
   end
   local authority = image.url:match("^https?://([^/%?#]+)") or "remote server"
   local host = authority:match("@([^@]+)$") or authority
   host = host:gsub(":%d+$", "")
   self.choose({ "Show image", "Cancel" }, {
      prompt = "Download image from " .. host .. "?",
   }, function(choice)
      if generation == self.generation and choice == "Show image" then load() end
   end)
end

function Images:clear()
   self.generation = self.generation + 1
   for pending in pairs(self.pending) do
      pending.active = false
      if pending.request then pending.request:cancel() end
      pending.finish()
   end
   self.pending = {}
   self.preview:close()
end

return Images

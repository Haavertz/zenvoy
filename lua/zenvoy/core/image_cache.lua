local Cache = {}
Cache.__index = Cache

local uv = vim.uv or vim.loop
local request_sequence = 0
local formats = {
   { mime = "image/png", extension = ".png", test = function(data) return data:sub(1, 8) == "\137PNG\r\n\26\n" end },
   { mime = "image/jpeg", extension = ".jpg", test = function(data) return data:sub(1, 3) == "\255\216\255" end },
   { mime = "image/gif", extension = ".gif", test = function(data)
      local signature = data:sub(1, 6)
      return signature == "GIF87a" or signature == "GIF89a"
   end },
   { mime = "image/webp", extension = ".webp", test = function(data)
      return data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP"
   end },
   { mime = "image/bmp", extension = ".bmp", test = function(data) return data:sub(1, 2) == "BM" end },
}

local function detect(data)
   for _, format in ipairs(formats) do
      if format.test(data) then return format end
   end
end

local function remove(path)
   if path then pcall(uv.fs_unlink, path) end
end

local function bytes_from_array(values, max_bytes)
   if type(values) == "string" then
      if #values > max_bytes then return nil, "Image exceeds the size limit" end
      return values
   end
   if type(values) ~= "table" or not vim.islist(values) then return nil, "Invalid image data" end
   if #values > max_bytes then return nil, "Image exceeds the size limit" end
   local chunks, char = {}, table.unpack or unpack
   for offset = 1, #values, 4096 do
      local bytes = {}
      for index = offset, math.min(offset + 4095, #values) do
         local value = values[index]
         if type(value) ~= "number" or value < 0 or value > 255 or value % 1 ~= 0 then
            return nil, "Invalid image byte data"
         end
         bytes[#bytes + 1] = value
      end
      chunks[#chunks + 1] = string.char(char(bytes))
   end
   return table.concat(chunks)
end

local function read_file(path, max_bytes)
   local stat = uv.fs_stat(path)
   if not stat or stat.type ~= "file" or stat.size <= 0 or stat.size > max_bytes then
      return nil, "Image is empty or exceeds the size limit"
   end
   local fd, err = uv.fs_open(path, "r", 384)
   if not fd then return nil, err end
   local data, read_error = uv.fs_read(fd, stat.size, 0)
   uv.fs_close(fd)
   if not data then return nil, read_error or "Unable to read image" end
   if not detect(data) then return nil, "Unsupported or invalid image format" end
   return data
end

local function ensure_directory(path)
   local ok, err = pcall(vim.fn.mkdir, path, "p", 448)
   if not ok or not uv.fs_stat(path) then
      return nil, "Unable to create image cache: " .. tostring(err or "directory unavailable")
   end
   return true
end

local function write_private(path, data)
   local fd, err = uv.fs_open(path, "w", 384)
   if not fd then return nil, err end
   local written, write_error = uv.fs_write(fd, data, 0)
   uv.fs_close(fd)
   if not written or written ~= #data then
      remove(path)
      return nil, write_error or "Unable to write image cache file"
   end
   pcall(uv.fs_chmod, path, 384)
   return true
end

local function digest(value)
   return vim.fn.sha256(value)
end

---@param process ZenvoyProcess
---@param options? { directory?: string, max_bytes?: integer }
function Cache.new(process, options)
   options = options or {}
   local max_bytes = options.max_bytes or 5 * 1024 * 1024
   assert(type(max_bytes) == "number" and max_bytes > 0 and max_bytes % 1 == 0,
      "image cache max_bytes must be a positive integer")
   return setmetatable({
      process = process,
      directory = options.directory or (vim.fn.stdpath("cache") .. "/zenvoy/images"),
      max_bytes = max_bytes,
   }, Cache)
end

function Cache:_find_cached(key)
   local base = self.directory .. "/" .. digest(key)
   for _, format in ipairs(formats) do
      local path = base .. format.extension
      local data = read_file(path, self.max_bytes)
      if data then return path end
   end
end

---@param image table Normalized image source from the message decoder.
---@param callback fun(err: string?, path: string?)
---@return ZenvoyRequest
function Cache:load(image, callback)
   local request = { cancelled = false, finished = false }
   function request:cancel()
      if self.finished or self.cancelled then return end
      self.cancelled = true
      if self.child then self.child:cancel() end
      remove(self.partial)
   end

   local function finish(err, path)
      if request.cancelled or request.finished then return end
      request.finished = true
      callback(err, path)
   end

   local key, source_data
   if image.kind == "embedded" then
      local data_error
      source_data, data_error = bytes_from_array(image.data, self.max_bytes)
      if not source_data then finish(data_error or "Invalid embedded image data"); return request end
      key = "embedded:" .. vim.base64.encode(source_data)
   elseif image.kind == "data" then
      if type(image.data) ~= "string" then finish("Invalid data image"); return request end
      if #image.data > math.ceil(self.max_bytes * 4 / 3) + 4 then
         finish("Image exceeds the size limit")
         return request
      end
      local ok, decoded = pcall(vim.base64.decode, image.data)
      if not ok or type(decoded) ~= "string" then finish("Invalid base64 image data"); return request end
      if #decoded > self.max_bytes then finish("Image exceeds the size limit"); return request end
      source_data, key = decoded, "data:" .. vim.base64.encode(decoded)
   elseif image.kind == "remote" then
      if type(image.url) ~= "string" or not image.url:lower():match("^https?://[^%s]+$") then
         finish("Only HTTP and HTTPS image URLs are supported")
         return request
      end
      key = "remote:" .. image.url
   else
      finish("Unknown image source")
      return request
   end

   if source_data then
      local format = detect(source_data)
      if not format then finish("Unsupported or invalid image format"); return request end
      if #source_data > self.max_bytes then finish("Image exceeds the size limit"); return request end
   end

   local cached = self:_find_cached(key)
   if cached then finish(nil, cached); return request end

   local created, directory_error = ensure_directory(self.directory)
   if not created then finish(directory_error); return request end

   local base = self.directory .. "/" .. digest(key)
   if source_data then
      local format = detect(source_data)
      local path = base .. format.extension
      local ok, err = write_private(path, source_data)
      if not ok then finish("Unable to cache image: " .. tostring(err)); return request end
      finish(nil, path)
      return request
   end

   request_sequence = request_sequence + 1
   request.partial = base .. "." .. tostring(request_sequence) .. ".part"
   local command = {
      "curl", "--fail", "--location", "--silent", "--show-error",
      "--max-time", "30", "--max-filesize", tostring(self.max_bytes),
      "--proto", "=http,https", "--proto-redir", "=http,https",
      "--output", request.partial, image.url,
   }
   request.child = self.process:run(command, function(err)
      if request.cancelled then remove(request.partial); return end
      if err then
         remove(request.partial)
         finish("Unable to download image: " .. err)
         return
      end
      local data, read_error = read_file(request.partial, self.max_bytes)
      if not data then
         remove(request.partial)
         finish(read_error)
         return
      end
      local format = detect(data)
      local path = base .. format.extension
      local renamed, rename_error = uv.fs_rename(request.partial, path)
      if not renamed then
         remove(request.partial)
         finish("Unable to save image: " .. tostring(rename_error))
         return
      end
      pcall(uv.fs_chmod, path, 384)
      finish(nil, path)
   end)
   return request
end

return Cache

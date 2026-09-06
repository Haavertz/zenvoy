local M = {}

---@param date string?
---@param now? integer
---@return string
function M.relative_date(date, now)
   if type(date) ~= "string" or date == "" then
      return "unknown"
   end

   local year, month, day, hour, minute, second = date:match(
      "(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):?(%d*)"
   )

   if not year then
      return "unknown"
   end

   local email_time = os.time({
      year = tonumber(year),
      month = tonumber(month),
      day = tonumber(day),
      hour = tonumber(hour),
      min = tonumber(minute),
      sec = tonumber(second) or 0,
   })

   if not email_time then
      return "unknown"
   end

   local difference = math.max(0, os.difftime(now or os.time(), email_time))
   local hours = math.floor(difference / 3600)
   local days = math.floor(difference / 86400)
   local weeks = math.floor(days / 7)
   local months = math.floor(days / 30)
   local years = math.floor(days / 365)

   if hours < 1 then
      return "just now"
   elseif hours < 24 then
      return hours == 1 and "1 hour ago" or hours .. " hours ago"
   elseif days < 14 then
      return days == 1 and "1 day ago" or days .. " days ago"
   elseif weeks < 4 then
      return weeks == 1 and "1 week ago" or weeks .. " weeks ago"
   elseif months < 12 then
      return months == 1 and "1 month ago" or months .. " months ago"
   end

   return years == 1 and "1 year ago" or years .. " years ago"
end

---@return integer
function M.max_date_width()
   return 13
end

return M

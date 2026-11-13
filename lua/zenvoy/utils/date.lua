local M = {}

-- Days since 1970-01-01 for a proleptic Gregorian date, independent of the local zone.
local function days_from_civil(year, month, day)
   year = month <= 2 and year - 1 or year
   local era = math.floor(year / 400)
   local year_of_era = year - era * 400
   local day_of_year = math.floor((153 * ((month + 9) % 12) + 2) / 5) + day - 1
   local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
   return era * 146097 + day_of_era - 719468
end

local function valid(year, month, day, hour, minute, second)
   return year and month and day and month >= 1 and month <= 12 and day >= 1 and day <= 31
      and hour >= 0 and hour <= 23 and minute >= 0 and minute <= 59 and second >= 0 and second <= 60
end

local function utc_epoch(year, month, day, hour, minute, second, offset_seconds)
   return days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset_seconds
end

---Convert a Himalaya date to a Unix timestamp.
---Accepts RFC 3339 strings ("2026-09-06T01:58:21Z", "2026-09-07 12:00:00-03:00") and
---mail-parser DateTime tables. Strings without a zone are read as local time.
---@param value string|table|nil
---@return integer?
function M.parse(value)
   if type(value) == "table" then
      local year, month, day = tonumber(value.year), tonumber(value.month), tonumber(value.day)
      local hour, minute, second = tonumber(value.hour) or 0, tonumber(value.minute) or 0, tonumber(value.second) or 0
      if not valid(year, month, day, hour, minute, second) then return nil end
      local offset = ((tonumber(value.tz_hour) or 0) * 3600 + (tonumber(value.tz_minute) or 0) * 60)
      if value.tz_before_gmt == true then offset = -offset end
      return utc_epoch(year, month, day, hour, minute, second, offset)
   end
   if type(value) ~= "string" or value == "" then return nil end
   local year, month, day, hour, minute, rest = value:match("^%s*(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d)(.*)$")
   if not year then return nil end
   year, month, day, hour, minute = tonumber(year), tonumber(month), tonumber(day), tonumber(hour), tonumber(minute)
   local second = tonumber(rest:match("^:(%d%d)")) or 0
   if not valid(year, month, day, hour, minute, second) then return nil end
   rest = rest:gsub("^:%d%d", ""):gsub("^%.%d+", "")
   if rest:match("^%s*[Zz]") then return utc_epoch(year, month, day, hour, minute, second, 0) end
   local sign, zone_hour, zone_minute = rest:match("^%s*([+-])(%d%d):?(%d%d)")
   if sign then
      local offset = tonumber(zone_hour) * 3600 + tonumber(zone_minute) * 60
      return utc_epoch(year, month, day, hour, minute, second, sign == "-" and -offset or offset)
   end
   return os.time({ year = year, month = month, day = day, hour = hour, min = minute, sec = second })
end

---@param epoch integer
---@param now? integer
---@return string
function M.relative(epoch, now)
   local difference = math.max(0, os.difftime(now or os.time(), epoch))
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

---@param date string?
---@param now? integer
---@return string
function M.relative_date(date, now)
   local epoch = M.parse(date)
   if not epoch then return "unknown" end
   return M.relative(epoch, now)
end

---Local wall-clock time, e.g. "Mon, Sep 7 2026 12:00".
---@param epoch integer
---@return string
function M.format(epoch)
   return ("%s %d %s"):format(os.date("%a, %b", epoch), tonumber(os.date("%d", epoch)), os.date("%Y %H:%M", epoch))
end

---Long form used in reply attributions, e.g. "Mon, Sep 7, 2026 at 12:00".
---@param epoch integer
---@return string
function M.format_long(epoch)
   return ("%s %d, %s"):format(os.date("%a, %b", epoch), tonumber(os.date("%d", epoch)), os.date("%Y at %H:%M", epoch))
end

---@return integer
function M.max_date_width()
   return 13
end

return M

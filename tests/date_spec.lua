vim.opt.runtimepath:prepend(vim.fn.getcwd())

local date = require("zenvoy.utils.date")
local now = os.time({
   year = 2026,
   month = 9,
   day = 6,
   hour = 12,
   min = 0,
   sec = 0,
})

assert(date.relative_date(nil, now) == "unknown")
assert(date.relative_date("invalid", now) == "unknown")
assert(date.relative_date("2026-09-06 11:30:00", now) == "just now")
assert(date.relative_date("2026-09-06 10:00:00", now) == "2 hours ago")
assert(date.relative_date("2026-09-05 12:00:00", now) == "1 day ago")
assert(date.relative_date("2026-08-23 12:00:00", now) == "2 weeks ago")
assert(date.max_date_width() == 13)

-- Zones are honored: both describe 2026-09-06 12:00 UTC.
assert(date.parse("2026-09-06T12:00:00Z") == 1788696000)
assert(date.parse("2026-09-06T09:00:00-03:00") == 1788696000)
assert(date.parse("2026-09-06 14:00+02:00") == 1788696000)
assert(date.parse({ year = 2026, month = 9, day = 6, hour = 9, minute = 0, second = 0,
   tz_before_gmt = true, tz_hour = 3, tz_minute = 0 }) == 1788696000)
assert(date.parse({ year = 2026, month = 13, day = 1 }) == nil)
assert(date.parse("2026-02-30x") == nil)
assert(date.relative(1788696000, 1788696000 + 3 * 86400) == "3 days ago")
local formatted = date.format(1788696000)
assert(formatted:match("^%a+, %a+ %d%d? 2026 %d%d:%d%d$"), formatted)
assert(date.format_long(1788696000):match("^%a+, %a+ %d%d?, 2026 at %d%d:%d%d$"))

print("date_spec: 15 tests passed")

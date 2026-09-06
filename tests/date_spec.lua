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

print("date_spec: 7 tests passed")

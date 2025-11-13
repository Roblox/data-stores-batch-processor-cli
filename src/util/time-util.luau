--!strict

--[[
    Time utility for handling Unix timestamps and datetime formatting.
]]

-- Native Libraries
local datetime = require("@lune/datetime")

-- TimeUtil
local TimeUtil = {}

--[[
    Converts a Unix timestamp in milliseconds to a DateTime string.
    @param timestamp number - Unix timestamp in milliseconds
    @return string - The converted DateTime string
]]
TimeUtil.FormatTimestamp = function(timestamp: number): string
    -- Convert milliseconds to seconds for DateTime.fromUnix
    local dt = datetime.fromUnixTimestamp(timestamp)
    return dt:formatLocalTime()
end

return TimeUtil
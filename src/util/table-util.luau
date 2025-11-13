--!strict

--[[
    Formats arguments into fixed-width blocks with separators.
]]

-- Local Libraries
local Constants = require('../shared/constants')

-- TableUtil
local TableUtil = {}

--[[
    Formats a value to fit within a block of specified width.
    If the value is too long, it will be truncated with "...".
    If the value is too short, it will be padded with spaces.
    Each block starts with a space.
    @param value any - The value to format
    @return string - The formatted value
]]
local function formatBlock(value: any): string
    local str = tostring(value)
    local result: string
    
    if #str > Constants.TableColumnWidth - 1 then
        result = " " .. string.sub(str, 1, Constants.TableColumnWidth - 4) .. "..."
    else
        -- Calculate padding needed to reach exactly width characters total
        local padding = Constants.TableColumnWidth - 1 - #str
        result = " " .. str .. string.rep(" ", padding)
    end

    return result
end

--[[
    Formats a line of values into fixed-width blocks separated by "|".
    @param ...any - The values to format
    @return string - The formatted line
]]
TableUtil.FormatLine = function(...: any): string
    local args = {...}
    local blocks = {}
    
    for _, value in ipairs(args) do
        table.insert(blocks, formatBlock(value))
    end
    
    return table.concat(blocks, "|")
end

--[[
    Formats a header line with the names of the columns.
    @param ...string - The column names
    @return string - The formatted header line
]]
TableUtil.FormatHeader = function(...: string): string
    return TableUtil.FormatLine(...)
end

--[[
    Formats a separator line with "-" characters and "+" at intersections.
    @param count number - The number of columns
    @return string - The formatted separator line
]]
TableUtil.FormatSeparator = function(count: number): string
    local blocks = {}   
    for _ = 1, count do
        table.insert(blocks, string.rep("-", Constants.TableColumnWidth))
    end
    return table.concat(blocks, "+")
end

return TableUtil
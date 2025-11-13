--!strict

--[[
    Generates random GUIDs (UUID v4) using basic Lua functions.
]]

-- Constants for GUID generation
local HEX_CHARS = "0123456789abcdef"
local GUID_TEMPLATE = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"

-- GuidUtil
local GuidUtil = {}

--[[
    Generates a random hex character
    @return string - A random hex character
]]
local function randomHexChar(): string
    local index = math.random(1, #HEX_CHARS)
    return string.sub(HEX_CHARS, index, index)
end

--[[
    Generates a random GUID (UUID v4).
    This implementation follows the UUID v4 specification:
    - 8 random hex digits
    - 4 random hex digits
    - 4 random hex digits (first digit is 4)
    - 4 random hex digits (first digit is 8, 9, A, or B)
    - 12 random hex digits
    @return string - A random GUID
]]
GuidUtil.GenerateGuid = function(): string
    local guid = GUID_TEMPLATE
    
    -- Replace each 'x' with a random hex digit
    guid = string.gsub(guid, "x", function()
        return randomHexChar()
    end)
    
    -- Replace 'y' with 8, 9, A, or B
    guid = string.gsub(guid, "y", function()
        local chars = "89ab"
        local index = math.random(1, #chars)
        return string.sub(chars, index, index)
    end)
    
    return guid
end

return GuidUtil
--!strict

--[[
    Utility for retrying functions with exponential backoff.
]]

-- Native Libraries
local task = require('@lune/task')

-- Local Libraries
local Types = require('../shared/types')

-- Constants
local DEFAULT_RETRY_COUNT = 10
local DEFAULT_RETRY_TIMEOUT_BASE = 0.5
local DEFAULT_RETRY_TIMEOUT_EXPONENTIAL_BACKOFF = 1.5

-- Retry Util
local RetryUtil = {}

--[[
    Function to call and retry a given function, up to maxAttempts times.
    This function waits pauseConstant * (pauseExponent ^ numAttempts) between retries for progressive exponential backoff.
    Calls are made with the functionCallHandler (default: pcall)
    and the results of this (in the form of success, errorMessage or ...) are
    returned.
    @param func Function - The function to call.
    @param optionalMaxAttempts number? - Maximum number of attempts.
    @param optionalPauseConstant number? - Optional constant pause time between retries.
    @param optionalPauseExponent number? - Optional exponent for exponential backoff.
    @param optionalFunctionCallHandler ((Function) -> (boolean, ...any))? - Optional function call handler (default: pcall).
    @return boolean - Whether the function succeeded.
    @return ...any - The result(s) of the function call or error message.
]]
RetryUtil.RetryAsync = function(
    func: Types.Function,
    optionalMaxAttempts: number?,
    optionalPauseConstant: number?,
    optionalPauseExponent: number?,
    optionalFunctionCallHandler: ((Types.Function) -> (boolean, ...any))?
): (boolean, ...any)
    local maxAttempts: number = optionalMaxAttempts or DEFAULT_RETRY_COUNT + 1
    local pauseConstant: number = optionalPauseConstant or DEFAULT_RETRY_TIMEOUT_BASE
    local pauseExponent: number = optionalPauseExponent or DEFAULT_RETRY_TIMEOUT_EXPONENTIAL_BACKOFF
    local functionCallHandler: Types.ProtectedFunctionHandler = optionalFunctionCallHandler or pcall

    local attempts = 0
    local success: boolean, result: { any }

    -- Retry logic with exponential backoff
    while attempts < maxAttempts do
        attempts += 1

        local returnValues: { any } = { functionCallHandler(func) }
        success = table.remove(returnValues, 1) :: boolean
        result = returnValues

        if success then
            break
        end

        local pauseTime = pauseConstant * (pauseExponent ^ attempts)
        local randomJitter = math.random(-200, 200) / 1000
        if attempts < maxAttempts then
            task.wait(pauseTime + randomJitter)
        end
    end

    -- Format pcall response
    if success then
        return success, table.unpack(result)
    else
        local errorMessage = not success and result[1] :: any or nil
        return success, errorMessage :: any
    end
end

return RetryUtil
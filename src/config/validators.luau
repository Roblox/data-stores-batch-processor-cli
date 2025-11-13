--!strict

--[[
    Contains the validation handlers for each of the config values. Validation handlers
    should validate the config value provided via these three means:

    1. Command Line Arguments
    2. Config File
    3. Command Prompt
    
    If the config value is valid, it should convert it to the correct type (+ default value if applicable).
]]

-- Native Libraries
local process = require('@lune/process')
local task = require('@lune/task')

-- External Libraries   
local llc_tasks = require('../../libs/llc_tasks/tasks')

-- Local Libraries   
local Constants = require('../shared/constants')
local FileIO = require('../util/fileio')
local Formulas = require('../util/formulas')
local OpenCloudClient = require('../util/open-cloud-client')
local RetryUtil = require('../util/retry-util')
local Types = require('../shared/types')

-- Constants
local API_KEY_VALIDATION_MAP_NAME = "_RBX_batch-process-api-key-validation"
local VALIDATION_KEY = "TEST"
local MEMORY_STORES_EXPIRATION_MINIMUM = 600
local MEMORY_STORES_EXPIRATION_MAXIMUM = 3888000
local MAX_ITEMS_PER_LIST_REQUEST = 500
local MAX_ITEMS_PER_LIST_REQUEST_EXCLUDE_DELETED_KEYS = 100

--[[
    Validates the universeId config
    @param configValue string - The config value
    @return (boolean, string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function universeIdValidator(configValue: string): (boolean, string)
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "'universeId' must be a number"
    end

    -- Check if the number is a valid integer
    if math.floor(tryGetNumber) ~= tryGetNumber then
        return false, "'universeId' must be an integer"
    end

    return true, tostring(tryGetNumber)
end

--[[
    Validates the placeId config
    @param configValue string - The config value
    @return (boolean, string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function placeIdValidator(configValue: string): (boolean, string)
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "'placeId' must be a number"
    end

    -- Check if the number is a valid integer
    if math.floor(tryGetNumber) ~= tryGetNumber then
        return false, "'placeId' must be an integer"
    end

    return true, tostring(tryGetNumber)
end

--[[
    Validates the callback config
    @param configValue string - The config value
    @return (boolean, string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function callbackValidator(configValue: string): (boolean, string)
    -- Check if the config value is an empty string
    local configString = tostring(configValue)
    if configString == "" then
        return false, "'callback' can't be an empty string"
    end

    -- Check if the file exists
    local file = FileIO.ReadFile(configString)
    if not file then
        return false, "'callback' must be a valid filepath"
    end

    return true, configString
end

--[[
    Validates the numProcessingInstances config
    @param configValue string - The config value
    @return (boolean, number | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function numProcessingInstancesValidator(configValue: string): (boolean, number | string)
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "'numProcessingInstances' must be an integer"
    end

    -- Check if the number is a positive value
    if tryGetNumber < 1 then
        return false, "'numProcessingInstances' must be a positive number"
    end

    -- Check if the number is a valid integer
    if math.floor(tryGetNumber) ~= tryGetNumber then
        return false, "'numProcessingInstances' must be an integer"
    end

    return true, tryGetNumber
end

--[[    
    Validates the outputDirectory config
    @param configValue string - The config value
    @return (boolean, string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function outputDirectoryValidator(configValue: string): (boolean, string)
    -- Default to the output directory if the config value provided is an empty string
    if configValue == "" then
        return true, "output"
    end
    return true, configValue
end

--[[    
    Validates the dataStoreName config
    @param configValue string - The config value
    @return (boolean, string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function dataStoreNameValidator(configValue: string): (boolean, string)
    -- Check if the config value is an empty string
    if configValue == "" then
        return false, "'dataStoreName' must be a non-empty string"
    end
    return true, configValue
end

--[[
    Validates the allScopes config
    @param configValue string - The config value
    @return (boolean, boolean | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function allScopesValidator(configValue: string): (boolean, boolean | string)
    -- Check if the config value is a boolean (config file or command line)
    if configValue == "true" or configValue == "1" then
        return true, true
    elseif configValue == "false" or configValue == "0" then
        return true, false
    end
    return false, "'allScopes' must be a value of 1 (true) or 0 (false)"
end

--[[
    Validates the dataStoreScope config
    @param configValue string - The config value
    @return (boolean, string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function dataStoreScopeValidator(configValue: string): (boolean, string)
    -- Default to the global scope if the config value provided is an empty string
    if configValue == "" then
        return true, "global"
    end
    return true, configValue
end

--[[    
    Validates the keyPrefix config
    @param configValue string - The config value
    @return (boolean, string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function keyPrefixValidator(configValue: string): (boolean, string)
    return true, configValue
end

--[[
    Validates the dataStorePrefix config
    @param configValue string - The config value
    @return (boolean, string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function dataStorePrefixValidator(configValue: string): (boolean, string)
    local configString: string = tostring(configValue)
    return true, configString
end

--[[
    Validates the excludeDeletedKeys config
    @param configValue string - The config value
    @return (boolean, boolean | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function excludeDeletedKeysValidator(configValue: string): (boolean, boolean | string)
    -- Check if the config value is a boolean (config file or command line)
    if configValue == "true" or configValue == "1" then
        return true, true
    elseif configValue == "false" or configValue == "0" then
        return true, false
    end
    return false, "'excludeDeletedKeys' must be a value of 1 (true) or 0 (false)"
end

--[[
    Validates the processItemRateLimit config
    @param configValue string - The config value
    @return (boolean, number | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function processItemRateLimitValidator(configValue: string): (boolean, number | string)
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "processItemRateLimit must be a number"
    end

    -- Check if the number is a positive value
    if tryGetNumber <= 0 then
        return false, "processItemRateLimit must be a positive number"
    end

    return true, tryGetNumber
end

--[[
    Validates the numRetries config
    @param configValue string - The config value
    @return (boolean, number | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function numRetriesValidator(configValue: string): (boolean, number | string)
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "'numRetries' must be a number"
    end

    -- Check if the number is a valid integer
    if math.floor(tryGetNumber) ~= tryGetNumber then
        return false, "'numRetries' must be an integer"
    end

    -- Check if the number is a non-negative value
    if tryGetNumber < 0 then
        return false, "'numRetries' must be a non-negative number"
    end

    return true, tryGetNumber
end

--[[    
    Validates the retryTimeoutBase config
    @param configValue string - The config value
    @return (boolean, number | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function retryTimeoutBaseValidator(configValue: string): (boolean, number | string)
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "'retryTimeoutBase' must be a number"
    end

    -- Check if the number is a non-negative value
    if tryGetNumber < 0 then
        return false, "'retryTimeoutBase' must be a non-negative number"
    end

    return true, tryGetNumber
end

--[[
    Validates the retryExponentialBackoff config
    @param configValue string - The config value
    @return (boolean, number | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function retryExponentialBackoffValidator(configValue: string): (boolean, number | string)   
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "'retryExponentialBackoff' must be a number"
    end

    -- Check if the number is a positive value
    if tryGetNumber <= 0 then
        return false, "'retryExponentialBackoff' must be a positive number"
    end

    return true, tryGetNumber
end

--[[
    Validates the maxTotalFailedItems config
    @param configValue string - The config value
    @return (boolean, number | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function maxTotalFailedItemsValidator(configValue: string): (boolean, number | string)
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "'maxTotalFailedItems' must be a number"
    end

    -- Check if the number is a valid integer
    if math.floor(tryGetNumber) ~= tryGetNumber then
        return false, "'maxTotalFailedItems' must be an integer"
    end

    -- Check if the number is a positive value
    if tryGetNumber <= 0 then
        return false, "'maxTotalFailedItems' must be a positive number"
    end

    return true, tryGetNumber
end

--[[
    Validates the maxItemsPerJob config
    @param configValue string - The config value
    @return (boolean, number | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function maxItemsPerJobValidator(configValue: string): (boolean, number | string)
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "'maxItemsPerJob' must be a number"
    end

    -- Check if the number is a valid integer
    if math.floor(tryGetNumber) ~= tryGetNumber then
        return false, "'maxItemsPerJob' must be an integer"
    end

    -- Check if the number is a positive value
    if tryGetNumber <= 0 then
        return false, "'maxItemsPerJob' must be a positive number"
    end

    -- Check if the number is less than the maximum number of items that can be listed
    if tryGetNumber > MAX_ITEMS_PER_LIST_REQUEST then
        return false, "'maxItemsPerJob' must be less than or equal to " .. MAX_ITEMS_PER_LIST_REQUEST
    end

    return true, tryGetNumber
end

--[[
    Validates the jobQueueMaxSize config
    @param configValue string - The config value
    @return (boolean, number | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function jobQueueMaxSizeValidator(configValue: string): (boolean, number | string)  
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "'jobQueueMaxSize' must be a number"
    end

    -- Check if the number is a valid integer
    if math.floor(tryGetNumber) ~= tryGetNumber then
        return false, "'jobQueueMaxSize' must be an integer"
    end

    -- Check if the number is a positive value
    if tryGetNumber <= 0 then
        return false, "'jobQueueMaxSize' must be a positive number"
    end

    return true, tryGetNumber
end

--[[
    Validates the errorLogMaxLength config
    @param configValue string - The config value
    @return (boolean, number | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function errorLogMaxLengthValidator(configValue: string): (boolean, number | string)
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "'errorLogMaxLength' must be a number"
    end

    -- Check if the number is a valid integer
    if math.floor(tryGetNumber) ~= tryGetNumber then
        return false, "'errorLogMaxLength' must be an integer"
    end

    -- Check if the number is a non-negative value
    if tryGetNumber < 0 then
        return false, "'errorLogMaxLength' must be a non-negative number"
    end

    return true, tryGetNumber
end 

--[[
    Validates the progressRefreshTimeout config
    @param configValue string - The config value
    @return (boolean, number | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function progressRefreshTimeoutValidator(configValue: string): (boolean, number | string)
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "'progressRefreshTimeout' must be a number"
    end

    -- Check if the number is a positive value
    if tryGetNumber <= 0 then
        return false, "'progressRefreshTimeout' must be a positive number"
    end

    return true, tryGetNumber
end

--[[
    Validates the memoryStoresExpiration config
    @param configValue string - The config value
    @return (boolean, number | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]    
local function memoryStoresExpirationValidator(configValue: string): (boolean, number | string)
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)
    if not tryGetNumber then
        return false, "'memoryStoresExpiration' must be a number"
    end

    -- Check if the number is within the bounds
    if tryGetNumber < MEMORY_STORES_EXPIRATION_MINIMUM or tryGetNumber > MEMORY_STORES_EXPIRATION_MAXIMUM then
        return false, "'memoryStoresExpiration' must be between " .. MEMORY_STORES_EXPIRATION_MINIMUM .. " and " .. MEMORY_STORES_EXPIRATION_MAXIMUM .. " seconds"
    end

    return true, tryGetNumber
end

--[[
    Validates the memoryStoresStorageLimit config
    @param configValue string - The config value
    @return (boolean, number | string) - A success boolean, and the validated config value or an error message if the config value is invalid
--]]
local function memoryStoresStorageLimitValidator(configValue: string): (boolean, number | string)
    -- Try to convert the config value to a number
    local tryGetNumber = tonumber(configValue)

    -- Check if the number is valid
    if not tryGetNumber then
        return false, "'memoryStoresStorageLimit' must be a number"
    end

    return true, tryGetNumber
end

--[[
    Validates that the failed items config is large enough to resume
    @param configValue number - The config value
    @param currentFailedItems number - The current number of failed items
    @return (boolean, string?) - A success boolean, and an error message if the config value is invalid
--]]
local function validateEnoughFailedItems(configValue: number, currentFailedItems: number): (boolean, string?)
    if configValue <= currentFailedItems then
        return false, "The 'maxTotalFailedItems' config is not large enough to resume the process. Please set the value of 'maxTotalFailedItems' to at least " .. (currentFailedItems + 1) .. " in your config file or using the --max-total-failed-items option."
    end
    return true
end

--[[
    Validates the memoryStoresStorageLimit config
    @param configs Types.ConfigValues - The configurations
    @return (boolean, string?) - A success boolean, and an error message if the config value is invalid
--]]
local function validateMemoryStoresStorageLimitBounds(configs: Types.ConfigValues): (boolean, string?)
    local memoryStoresStorageLimit = tonumber(configs.memoryStoresStorageLimit)

    -- Get the min value for the config
    local minStorage = Formulas.CalculateMinStorage(configs)
    local maxStorage = Formulas.CalculateMaxStorage(configs)

    -- Check if the number is less than the min value
    if memoryStoresStorageLimit < minStorage and memoryStoresStorageLimit ~= -1 then
        return false, "'memoryStoresStorageLimit' must be at least " .. minStorage .. " kb in order to run."
    end

    -- Get the max value for the config
    if memoryStoresStorageLimit == -1 or memoryStoresStorageLimit > maxStorage then
        configs.memoryStoresStorageLimit = maxStorage
    end

    return true
end

--[[
    Validates the maxItemsPerJob config with excluded deleted keys
    @param configs Types.ConfigValues - The configurations
    @return (boolean, string?) - A success boolean, and an error message if the config value is invalid
--]]
local function validateMaxItemsPerJobWithExcludedDeletedKeys(configs: Types.ConfigValues): (boolean, string?)
    -- If the excludeDeletedKeys config is false, then we don't need to validate the maxItemsPerJob config
    if not configs.excludeDeletedKeys then
        return true
    end

    -- Validate that the maxItemsPerJob is an allowable value for excluding deleted keys
    local maxItemsPerJob = tonumber(configs.maxItemsPerJob)
    if maxItemsPerJob > MAX_ITEMS_PER_LIST_REQUEST_EXCLUDE_DELETED_KEYS then
        return false, "'maxItemsPerJob' must be less than or equal to " .. MAX_ITEMS_PER_LIST_REQUEST_EXCLUDE_DELETED_KEYS .. " when 'excludeDeletedKeys' is true."
    end

    return true
end

--[[
    Validates the API Key Permissions
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
    @param apiKey string - The API Key
    @return (boolean, string?) - A success boolean, and an error message if the config value is invalid
--]]
local function validateAPIKey(openCloudClient: OpenCloudClient.OpenCloudClient, apiKey: string): (boolean, string?)
    -- Validate Memory Stores Set
    local setSessionStatus = openCloudClient.createSortedMapEntry(API_KEY_VALIDATION_MAP_NAME, VALIDATION_KEY, VALIDATION_KEY, nil, 5)
    if setSessionStatus.status == 403 then
        return false, "The API Key is invalid. Please verify the following:\n1. Universe Id\n2. API Key\n3. API Key Permission for memory-store.sorted-map write"
    end

    -- Validate Memory Stores Get
    local getSessionStatus = openCloudClient.getSortedMapEntry(API_KEY_VALIDATION_MAP_NAME, VALIDATION_KEY)
    if getSessionStatus.status == 403 then
        return false, "The API Key is invalid. Please verify the following:\n1. Universe Id\n2. API Key\n3. API Key Permission for memory-store.sorted-map read"
    end

    -- Validate Data Stores List
    local listDataStoresStatus = openCloudClient.listDataStoreEntries(API_KEY_VALIDATION_MAP_NAME, "global")
    if listDataStoresStatus.status == 403 then
        return false, "The API Key is invalid. Please verify the following:\n1. Universe Id\n2. API Key\n3. API Key Permission for universe-datastores.objects:list"
    end

    -- Validate Data Stores Get
    local getDataStoreEntryStatus = openCloudClient.getDataStoreEntry(API_KEY_VALIDATION_MAP_NAME, "global", VALIDATION_KEY)
    if getDataStoreEntryStatus.status == 403 then
        return false, "The API Key is invalid. Please verify the following:\n1. Universe Id\n2. API Key\n3. API Key Permission for universe-datastores.objects:read"
    end

    -- Validate Data Stores Set
    local setDataStoreEntryStatus = openCloudClient.createDataStoreEntry(API_KEY_VALIDATION_MAP_NAME, "global", VALIDATION_KEY, VALIDATION_KEY)
    if setDataStoreEntryStatus.status == 403 then
        return false, "The API Key is invalid. Please verify the following:\n1. Universe Id\n2. API Key\n3. API Key Permissions for universe-datastores.objects:create and universe-datastores.control:create"
    end

    -- Validate Ordered Data Stores Get
    local getOrderedDataStoreRangeStatus = openCloudClient.getOrderedDataStoreRange(VALIDATION_KEY, "global", true, 1)
    if getOrderedDataStoreRangeStatus.status == 403 then
        return false, "The API Key is invalid. Please verify the following:\n1. Universe Id\n2. API Key\n3. API Key Permission for universe.ordered-data-store.scope.entry:read"
    end

    return true
end

--[[
    Validates the callback using a Session Task
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
    @param callback string - The callback function filepath
    @param universeId number | string - The universe ID
    @param placeId number | string - The place ID
    @return (boolean, string?) - A success boolean, and an error message if the config value is invalid
--]]
local function validateCallbackWithSessionTask(openCloudClient: OpenCloudClient.OpenCloudClient, callback: string, universeId: number | string, placeId: number | string): (boolean, string?)
    local file = FileIO.ReadFile(callback)
    if not file then
        return false, "'callback' must be a valid filepath"
    end

     -- Create the callback function wrapper
    local callbackWrapper = "local processItemBuilder = function()\n" .. file :: string .. "\nend\n"
    local validationScript = callbackWrapper .. [[
        return function()
            local processItem = processItemBuilder()
            return 0
        end
    ]]
        
    -- Check that the Session Task doesn't fail
    local validateCallbackSession = llc_tasks.create(validationScript, {
        api_key = process.env['API_KEY'],
        universe_id = universeId,
        place_id = placeId
    })
    local validateCallbackSuccess: boolean, validateCallbackResult: any = RetryUtil.RetryAsync(function()
        local validateCallbackRes, validateCallbackError = validateCallbackSession:start()
        if validateCallbackError then
            error("")
        end
        return validateCallbackRes
    end, Constants.SessionTaskRetryConfig.MaxAttempts, Constants.SessionTaskRetryConfig.TimeoutBase, Constants.SessionTaskRetryConfig.TimeoutExponentialBackoff)
    if not validateCallbackSuccess then
        return false, "The callback could not be validated with a Session Task. Please verify the following:\n1. Universe ID\n2. Place ID\n3. API Key\n4. API Key Permission for luau-execution-sessions write\n5. There are available Session Tasks"
    end

    local sessionId = validateCallbackResult.task_create_res.path

    -- Check if the callback succeeded after a short delay
    repeat 
        task.wait(1)
        local getSessionStatus = openCloudClient.getLuauExecutionSessionStatus(sessionId)
        if getSessionStatus.body and getSessionStatus.body.state == "FAILED" then
            return false, "The callback is invalid. Please ensure the callback is a valid Luau script and try again."
        end
    until getSessionStatus.status == 200 and getSessionStatus.body.state == "COMPLETE"

    return true
end

--[[
    The validation handlers for each of the config values.
]]
local Validators: { [string]: (any) -> (boolean, string | number | boolean) } = {
    ["universeId"] = universeIdValidator,
    ["placeId"] = placeIdValidator,
    ["callback"] = callbackValidator,
    ["numProcessingInstances"] = numProcessingInstancesValidator,
    ["outputDirectory"] = outputDirectoryValidator,
    ["dataStoreName"] = dataStoreNameValidator,
    ["allScopes"] = allScopesValidator,
    ["dataStoreScope"] = dataStoreScopeValidator,
    ["keyPrefix"] = keyPrefixValidator,
    ["dataStorePrefix"] = dataStorePrefixValidator,
    ["excludeDeletedKeys"] = excludeDeletedKeysValidator,
    ["processItemRateLimit"] = processItemRateLimitValidator,
    ["numRetries"] = numRetriesValidator,
    ["retryTimeoutBase"] = retryTimeoutBaseValidator,
    ["retryExponentialBackoff"] = retryExponentialBackoffValidator,
    ["maxTotalFailedItems"] = maxTotalFailedItemsValidator,
    ["maxItemsPerJob"] = maxItemsPerJobValidator,
    ["jobQueueMaxSize"] = jobQueueMaxSizeValidator,
    ["errorLogMaxLength"] = errorLogMaxLengthValidator,
    ["progressRefreshTimeout"] = progressRefreshTimeoutValidator,
    ["memoryStoresExpiration"] = memoryStoresExpirationValidator,
    ["memoryStoresStorageLimit"] = memoryStoresStorageLimitValidator
}

return {
    Validators = Validators,
    ValidateAPIKey = validateAPIKey,
    ValidateCallbackWithSessionTask = validateCallbackWithSessionTask,
    ValidateEnoughFailedItems = validateEnoughFailedItems,
    ValidateMaxItemsPerJobWithExcludedDeletedKeys = validateMaxItemsPerJobWithExcludedDeletedKeys,
    ValidateMemoryStoresStorageLimitBounds = validateMemoryStoresStorageLimitBounds
}
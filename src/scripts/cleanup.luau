--!strict

--[[
    Runs a cleanup job to remove all batch processing-related data from memory stores and data stores for a given batch process.

    This script runs in the engine in Roblox's cloud via Open Cloud Luau Execution
]]

-- Services
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")

-- Types
type SortedMapItem = {
    key: string, -- The key of the item
    sortKey: any, -- The sort key of the item
    value: any -- The value of the item
}

type Function = (...any) -> ...any -- A function that takes any number of arguments and returns any number of results
type ProtectedFunctionHandler = (Function) -> (boolean, ...any) -- A function that takes a function and returns a boolean and any number of results

-- Constants for batch processing
local BATCH_PROCESS_MAP_NAME = "_RBX_batch-processes" -- The name of the batch process map
local BATCH_PROCESS_TASK_STATUS_MAP_NAME = "_RBX_batch-process-task-status" -- The name of the batch process task status map
local BATCH_PROCESS_STORAGE_POOL_MAP_NAME = "_RBX_batch-process-storage-pool" -- The name of the batch process storage pool map

-- Constants for retry logic
local DEFAULT_RETRY_COUNT = 10
local DEFAULT_RETRY_TIMEOUT_BASE = 0.5
local DEFAULT_RETRY_TIMEOUT_EXPONENTIAL_BACKOFF = 1.5

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
local function retryAsync(
    func: Function,
    optionalMaxAttempts: number?,
    optionalPauseConstant: number?,
    optionalPauseExponent: number?,
    optionalFunctionCallHandler: ((Function) -> (boolean, ...any))?
): (boolean, ...any)
    local maxAttempts: number = optionalMaxAttempts or DEFAULT_RETRY_COUNT + 1
    local pauseConstant: number = optionalPauseConstant or DEFAULT_RETRY_TIMEOUT_BASE
    local pauseExponent: number = optionalPauseExponent or DEFAULT_RETRY_TIMEOUT_EXPONENTIAL_BACKOFF
    local functionCallHandler: ProtectedFunctionHandler = optionalFunctionCallHandler or pcall

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

--[[
    This function will remove all items from the queue.
    @param queue MemoryStoreQueue - The queue to remove the items from
]]
local function clearQueue(queue: MemoryStoreQueue): ()
    -- Remove all items from the queue. This may take some time since it will also wait for all items to be visible.
    -- Jobs that were not completed by the time its session tasks exited may still exist, but are invisible on the job queue.
    -- We can only guarantee that all jobs are removed if we wait for all items to be visible. If we accidentally leave some jobs on the queue,
    -- they may be picked up by a new batch process with the same name, which could cause issues.
    print("Removing queue items...")
    while(queue:GetSizeAsync(false) > 0) do
        -- Get a page of items from the queue
        local readSuccess: boolean, readResult: any, id: string = retryAsync(function()
            return queue:ReadAsync(100)
        end)
        if not readSuccess then
            error("Error: Failed to read job from queue. Reason - " .. readResult :: string)
        end

        -- Remove the items from the queue
        local removeSuccess: boolean, removeResult: string = retryAsync(function()
            queue:RemoveAsync(id)
        end)
        if not removeSuccess then
            error("Error: Failed to remove job from queue. Reason - " .. removeResult)
        end
    end
end

--[[
    This function will remove all items from the failed items map.
    @param map MemoryStoreSortedMap - The map to remove the items from
]]
local function clearSortedMap(map: MemoryStoreSortedMap): ()
    -- Loop until we have removed all items from the map
    local exclusiveLowerBound = nil
    while true do
        -- Get a page of items from the map
        local getRangeSuccess: boolean, getRangeResult: { SortedMapItem } | string = retryAsync(function()
            return map:GetRangeAsync(Enum.SortDirection.Ascending, 200, exclusiveLowerBound)
        end)
        if not getRangeSuccess then
            error("Error: Failed to get range of failed items. Reason - " .. getRangeResult :: string)
        end

        local items = getRangeResult :: { SortedMapItem }
        if #items == 0 then
            break
        end

        -- Remove the items from the map
        for _, item in ipairs(items) do
            local removeSuccess: boolean, removeResult: string = retryAsync(function()
                map:RemoveAsync(item.key)
            end)
            if not removeSuccess then
                error("Error: Failed to remove failed item. Reason - " .. removeResult)
            end
        end

        -- Get the next bound
        exclusiveLowerBound = { 
            key = items[#items].key, 
            sortKey = items[#items].sortKey 
        }
    end
end

--[[
    This function will remove all items from the ordered data store.
    @param dataStore OrderedDataStore - The data store to remove the items from
]]
local function clearOrderedDataStore(dataStore: OrderedDataStore): ()
    -- Loop until we have removed all items from the data store
    local getSortedSuccess: boolean, getSortedResult: string | DataStorePages = retryAsync(function()
        return dataStore:GetSortedAsync(false, 100)
    end)
    if not getSortedSuccess then
        error("Error: Failed to get sorted data store. Reason - " .. getSortedResult :: string)
    end

    local pages = getSortedResult :: DataStorePages
    while true do
        for _, entry in ipairs(pages:GetCurrentPage()) do
            -- Remove each item from the data store
            local key = entry.key
            local removeSuccess: boolean, removeResult: string = retryAsync(function()
                dataStore:RemoveAsync(key)
            end)
            if not removeSuccess then
                error("Error: Failed to remove failed item. Reason - " .. removeResult)
            end
        end

        if pages.IsFinished then
            break
        end

        local advanceSuccess: boolean, advanceResult: string = retryAsync(function()
            pages:AdvanceToNextPageAsync()
        end)
        if not advanceSuccess then
            error("Error: Failed to advance to next page. Reason - " .. advanceResult)
        end
    end
end

--[[
    This function will remove the process entry from the map.
    @param map MemoryStoreSortedMap - The map to remove the process entry from
    @param processName string - The name of the process to remove
]]
local function cleanupSortedMapEntry(map: MemoryStoreSortedMap, processName: string): ()
    local success, result = retryAsync(function()
        map:RemoveAsync(processName)
    end)
    if not success then
        error("Error: Failed to remove process task status. Reason - " .. result :: string)
    end
end

--[[
    This function will remove the process entry from the data store.
    @param dataStore DataStore - The data store to remove the process entry from
    @param processName string - The name of the process to remove
]]
local function cleanupDataStoreEntry(dataStore: DataStore, processName: string): ()
    local success, result = retryAsync(function()
        dataStore:RemoveAsync(processName)
    end)
    if not success then
        error("Error: Failed to remove process task status. Reason - " .. result :: string)
    end
end

--[[
    Main entry point for the cleanup script.
    This function initializes the environment and kicks off the cleanup.
    @param processName string - Name of the batch process
    @param configs Types.ProcessKeysConfigs|Types.ProcessDatastoresConfigs - Configuration object containing settings for the batch process
    @return number - 0 on successful completion
]]
return function(processName: string)  
    -- Initialize memory store objects
    local itemPageMapName = "_RBX_batch-process-pages" .. "-" .. processName
    local failedItemLogsMapName = "_RBX_batch-process-failed-item-logs" .. "-" .. processName
    local queueName = "_RBX_batch-process-job-queue" .. "-" .. processName
    local failedItemsOrderedDataStoreName = "_RBX_batch-process-failed-items" .. "-" .. processName
    local batchProcessMap = MemoryStoreService:GetSortedMap(BATCH_PROCESS_MAP_NAME)
    local itemPageMap = MemoryStoreService:GetSortedMap(itemPageMapName)
    local failedItemLogsMap = MemoryStoreService:GetSortedMap(failedItemLogsMapName)
    local jobQueue = MemoryStoreService:GetQueue(queueName, 300)
    local storagePoolMap = MemoryStoreService:GetSortedMap(BATCH_PROCESS_STORAGE_POOL_MAP_NAME)
    local failedItemsOrderedDataStore = DataStoreService:GetOrderedDataStore(failedItemsOrderedDataStoreName)
    local processTaskStatusMap = MemoryStoreService:GetSortedMap(BATCH_PROCESS_TASK_STATUS_MAP_NAME)
    local batchProcessDataStoresMap = DataStoreService:GetDataStore(BATCH_PROCESS_MAP_NAME)

    -- Cleanup all memory stores and data stores
    print("Clearing job queue...")
    clearQueue(jobQueue)
    print("Clearing failed item logs map...")
    clearSortedMap(failedItemLogsMap)
    print("Clearing item page map...")
    clearSortedMap(itemPageMap)
    print("Clearing failed items ordered data store...")
    clearOrderedDataStore(failedItemsOrderedDataStore)
    print("Clearing storage pool map...")
    cleanupSortedMapEntry(storagePoolMap, processName)
    print("Cleaning up process task status entry...")
    cleanupSortedMapEntry(processTaskStatusMap, processName)
    print("Cleaning up batch process entry...")
    cleanupSortedMapEntry(batchProcessMap, processName)
    print("Cleaning up batch process data stores entry...")
    cleanupDataStoreEntry(batchProcessDataStoresMap, processName)
    print("Cleanup complete!")
    return 0
end
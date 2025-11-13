--[[
    Stage 2 of the batch processing system.
    This stage dequeues 'jobs' from the queue, which each contain a page of items to process.
    It processes each item in parallel.

    This script runs in the engine in Roblox's cloud via Open Cloud Luau Execution
]]

-- Services
local MemoryStoreService = game:GetService("MemoryStoreService")

-- Types
type ExecutionConfigs = {
    universeId: string, -- The universe ID
    placeId: string, -- The place ID
    callback: string, -- The callback function filepath
    numProcessingInstances: number, -- The number of processing instances to run
    outputDirectory: string, -- The output directory
}

type ProcessingConfigs = {
    processItemRateLimit: number, -- The rate limit for processing items
    numRetries: number, -- The number of retries before failing items
    retryTimeoutBase: number, -- The base timeout for retries
    retryExponentialBackoff: number, -- The exponential backoff for retries
    maxTotalFailedItems: number, -- The maximum number of failed items before failing a batch process
    maxItemsPerTask: number, -- The maximum number of items in a single job
    jobQueueMaxSize: number, -- The maximum number of jobs on the job queue
    errorLogMaxLength: number, -- The maximum length of the error log
    progressRefreshTimeout: number, -- The timeout for refreshing progress
    memoryStoresExpiration: number, -- The expiration time for memory stores
    memoryStoresStorageLimit: number -- The storage limit for memory stores
}

type ScanKeysConfigs = { 
    dataStoreName: string, -- The name of the DataStore
    allScopes: boolean, -- Whether to scan all scopes
    dataStoreScope: string, -- The scope of the DataStore
    keyPrefix: string, -- The prefix of the keys to process
    excludeDeletedKeys: boolean -- Whether to exclude deleted keys
}

type ScanDatastoresConfigs = {
    dataStorePrefix: string -- The prefix of the DataStore
}

type ProcessKeysConfigs = ExecutionConfigs & ProcessingConfigs & ScanKeysConfigs
type ProcessDatastoresConfigs = ExecutionConfigs & ProcessingConfigs & ScanDatastoresConfigs

type ItemPageInfo = {
    nextCursor: string, -- The cursor for the next page to scan
    createTime: number, -- The time this page was created
    updateTime: number, -- The last time this page was updated
    processedItems: number, -- The total items processed successfully on this page
    failedItems: number, -- The total items failed on this page
    status: string, -- "InProgress" or "Done"
    failedItemsList: { string } -- The list of failed items
}

type Job = {
    pageIndex: number, -- The index of the page to process
    nextCursor: string, -- The cursor for the next page to scan
    items: { string } -- The list of DataStore keys to process
}

type StoragePool = {
    bytes: number, -- The total storage bytes for the batch process
    numFailedItemLogs: number, -- The number of failed items since the last update
}

type FailedItem = {
    sessionPath: string, -- The session path from which the item originated
    error: string, -- The error log
    time: number -- The time the item failed
}

type SortedMapItem = {
    key: string, -- The key of the item
    sortKey: any, -- The sort key of the item
    value: any -- The value of the item
}

type Function = (...any) -> ...any -- A function that takes any number of arguments and returns any number of results
type ProcessCallback = (item: string) -> any -- A function that takes an item and returns anything
type ProtectedFunctionHandler = (Function) -> (boolean, ...any) -- A function that takes a function and returns a boolean and any number of results

-- Constants for batch processing
local BATCH_PROCESS_GUID_TO_SESSION_PATHS_MAP_NAME = "_RBX_batch-process-guid-to-session-paths"
local BATCH_PROCESS_STORAGE_POOL_MAP_NAME = "_RBX_batch-process-storage-pool"

-- Constants for retry logic
local DEFAULT_RETRY_COUNT = 10
local DEFAULT_RETRY_TIMEOUT_BASE = 0.5
local DEFAULT_RETRY_TIMEOUT_EXPONENTIAL_BACKOFF = 1.5

-- Constants for storage tracking
local FAILED_ITEM_LOG_OVERHEAD_BYTES = 209 -- Length of the failed item log without the truncated error log
local BYTES_PER_KILOBYTE = 1024 -- The number of bytes in a kilobyte

-- Other Constants
local FAILED_ITEM_LOGS_EXPIRATION = 300

-- Global variables
local SESSION_PATH: string -- The Session Path
local PROCESS_NAME: string -- The name of the batch process
local CONFIGS: ProcessKeysConfigs | ProcessDatastoresConfigs -- The configuration object

-- Global references to memory store objects
local itemPageMap: MemoryStoreSortedMap -- Tracks the state of each page being processed
local failedItemLogsMap: MemoryStoreSortedMap -- Stores information about failed items
local jobQueue: MemoryStoreQueue -- Queue containing items to be processed
local guidToSessionPathsMap: MemoryStoreSortedMap -- Stores a mapping from the id to the session paths
local storagePoolMap: MemoryStoreSortedMap -- Stores the total storage pool in bytes for the batch process

-- Process item callback function provided by the caller 
-- (processItemBuilder() is injected to the top of the script)
local processItem: ProcessCallback

-- stores the staggered task executor instance
local staggeredTaskExecutor

--[[
    StaggeredTaskExecutor allows callbacks to be queued and executed with a delay between each execution
    @return The StaggeredTaskExecutor class
--]]
local StaggeredTaskExecutor = function()
    local StaggeredTaskExecutor = {}
    StaggeredTaskExecutor.__index = StaggeredTaskExecutor

    --[[
        Creates a new StaggeredTaskExecutor instance
        @param timeBetween number? - Minimum time between task executions in seconds (default: 0)
        @return StaggeredTaskExecutorClass - A new StaggeredTaskExecutor instance
    ]]
    function StaggeredTaskExecutor.new(timeBetween: number?)
        local self = {
            _queue = {},
            _timeBetween = (timeBetween or 0),
        }
        setmetatable(self, StaggeredTaskExecutor)
        return self
    end

    --[[
        Submits a callback to be executed by the queue.
        @param callback Callback - The function to execute
    ]]
    function StaggeredTaskExecutor.submitTask(self, callback: Function)
        table.insert(self._queue, callback)
    end

    --[[
        Starts all tasks in the queue with a staggered delay between each execution,
        and waits for all tasks to complete.
    ]]
    function StaggeredTaskExecutor.executeTasksAsync(self)
        local tasksRemaining = #self._queue
        while #self._queue > 0 do
            local entry = table.remove(self._queue, 1) :: Function
            task.defer(function()
                entry()
                tasksRemaining -= 1
            end)
            task.wait(self._timeBetween)
        end

        -- Wait for all tasks to complete
        while(tasksRemaining > 0) do
            task.wait()
        end
    end
    
    return StaggeredTaskExecutor
end

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

-- Counters for tracking processing progress
local processedItems: number -- Number of items successfully processed
local failedItems: number -- Number of items that failed to process
local failedItemsList: { string } -- The list of failed items
local failedItemLogs: { string: FailedItem } -- The list of failed items logs

--[[
    Processes a single item with retry logic
    @param item string - The item to process
]]
local function processAndUpdate(item: string): ()
    local function tryProcessItem(): ()
        processItem(item)
    end

    -- retry the process item function and store full error traceback
    local processItemSuccess: boolean, errorLogs: any = retryAsync(
        tryProcessItem,
        CONFIGS.numRetries + 1,
        CONFIGS.retryTimeoutBase,
        CONFIGS.retryExponentialBackoff,
        function(func: Function): (boolean, ...any)
            return xpcall(func, function(err)
                local stacktrace = debug.traceback(err, 2)
                return string.gsub(stacktrace, "\n", "; ")
            end)
        end
    )

    -- Handle failed items
    if processItemSuccess then
        processedItems += 1
    else
        failedItems += 1

        -- Create a failed item
        local failedItemLog: FailedItem = {
            sessionPath = SESSION_PATH,
            error = string.len(errorLogs) > CONFIGS.errorLogMaxLength and string.sub(errorLogs, 1, CONFIGS.errorLogMaxLength) .. "..." or errorLogs,
            time = DateTime.now().UnixTimestamp
        }

        -- Add the failed item to the failed items list and logs
        table.insert(failedItemsList, item)
        failedItemLogs[item] = failedItemLog

        -- Print the error to session logs
        print("Error: Failed to process item " .. item .. ". Reason - " .. errorLogs :: string)
    end
end

--[[
    Gets the session path from the guid to session paths map
    @return string - The session path
]]
local function getSessionPathAndUpdateStatus(id: string): string
    local getSessionPathSuccess: boolean, getSessionPathResult: string = retryAsync(function()
        local sessionPath: string = guidToSessionPathsMap:GetAsync(id)
        if not sessionPath or sessionPath == "" then
            error("Session path has not been loaded yet.")
        end
        return sessionPath
    end)
    if not getSessionPathSuccess then
        error("Error: Failed to get session path. Reason - " .. getSessionPathResult :: string)
    end
    return getSessionPathResult
end

--[[
    Main stage 2 processing function that:
    1. Reads items from the queue
    2. Processes items in parallel with rate limiting
    3. Updates page status when processing is complete
    4. Handles EOF signals to terminate processing
    This is an async function that manages the entire stage 2 workflow
]]
local function processStage2Async(): ()
    while true do
        -- Read one page from queue
        local readTaskSuccess: boolean, readTaskResult: { Job | string } | string, id: string = retryAsync(function()
            return jobQueue:ReadAsync(1, false)
        end)
        if not readTaskSuccess then
            error("Error: Failed to remove job from queue. Reason - " .. readTaskResult :: string)
        end

        local items = readTaskResult :: { Job | string}

        -- Check for EOF signal and terminate processing
        if items[1] == 'EOF' then
            print("Info: EOF signal received")
            local removeIdSuccess: boolean, removeIdResult: string = retryAsync(function()
                jobQueue:RemoveAsync(id)
            end)
            if not removeIdSuccess then
                error("Error: Failed to remove EOF from queue. Reason - " .. removeIdResult :: string)
            end
            break
        end

        -- Check if there are items to process
        if items and #items > 0 then
            local pageData = items[1] :: Job
            local pageIndex: number = pageData.pageIndex
            local pageKey = PROCESS_NAME .. "-" .. pageIndex
            print("Info: Processing page " .. pageKey)

            -- Initialize counters for this page
            processedItems = 0
            failedItems = 0
            failedItemsList = {}
            failedItemLogs = {} :: { string: FailedItem }

            -- Process all items in the page in parallel
            for _, item in ipairs(pageData.items) do
                staggeredTaskExecutor:submitTask(function()
                    processAndUpdate(item)
                end)
            end

            -- Wait for all tasks to complete while maintaining rate limit
            staggeredTaskExecutor:executeTasksAsync()
            print("Info: All tasks in page " .. pageKey .. " completed")

            -- Update item page status with processing results
            local updatePageSuccess: boolean, updatePageResult: string = retryAsync(function()
                itemPageMap:UpdateAsync(pageKey, function(currentValue)
                    -- Only update if the cursor matches to prevent race conditions
                    if currentValue and currentValue.nextCursor == pageData.nextCursor then
                        currentValue.processedItems = processedItems
                        currentValue.failedItems = failedItems
                        currentValue.status = "Done"
                        currentValue.failedItemsList = failedItemsList
                        currentValue.updateTime = DateTime.now().UnixTimestamp
                        return currentValue
                    end
                    return nil -- Cancel update if cursor doesn't match
                end, CONFIGS.memoryStoresExpiration)
            end)
            if not updatePageSuccess then
                error("Error: Failed to update page. Reason - " .. updatePageResult :: string)
            end

            -- Remove processed item from queue
            local removeIdSuccess: boolean, removeIdResult: string = retryAsync(function()
                jobQueue:RemoveAsync(id)
            end)
            if not removeIdSuccess then
                error("Error: Failed to remove job from queue. Reason - " .. removeIdResult :: string)
            end

            -- Update the storage pool for this instance
            local numFailedItemLogsToStore = 0
            local getStoragePoolSuccess: boolean, getStoragePoolResult: string | StoragePool = retryAsync(function()
                storagePoolMap:UpdateAsync(PROCESS_NAME, function(currentStoragePool: StoragePool)
                    -- Figure out how many failed items to store
                    local storageQuota = (CONFIGS.memoryStoresStorageLimit * BYTES_PER_KILOBYTE - currentStoragePool.bytes) / CONFIGS.numProcessingInstances
                    local maxItemLogsToStore = math.floor(storageQuota / (FAILED_ITEM_LOG_OVERHEAD_BYTES + CONFIGS.errorLogMaxLength))
                    numFailedItemLogsToStore = math.min(maxItemLogsToStore, #failedItemsList)

                    -- Update the storage pool
                    currentStoragePool.bytes += (numFailedItemLogsToStore * (FAILED_ITEM_LOG_OVERHEAD_BYTES + CONFIGS.errorLogMaxLength))
                    currentStoragePool.numFailedItemLogs += numFailedItemLogsToStore
                    return currentStoragePool
                end, CONFIGS.memoryStoresExpiration)
            end)
            if not getStoragePoolSuccess then
                error("Error: Failed to get storage pool. Reason - " .. getStoragePoolResult :: string)
            end

            -- Add the failed items logs to the failed items map
            local counter = 0
            for item, failedItemLog in pairs(failedItemLogs) do
                if counter >= numFailedItemLogsToStore then
                    break
                end
                counter += 1

                local setFailedItemSuccess: boolean, setFailedItemResult: string = retryAsync(function()
                    failedItemLogsMap:SetAsync(item, failedItemLog, FAILED_ITEM_LOGS_EXPIRATION)
                end)

                if not setFailedItemSuccess then
                    error("Error: Failed to set failed item. Reason - " .. setFailedItemResult :: string)
                end
            end
        end
    end
end

--[[
    Main entry point for the batch processing script.
    This function initializes the environment and kicks off the stage 2 processing.
    @param guid string - The CLI-generated guid of the batch process
    @param processName string - Name of the batch process
    @param configs Types.ProcessKeysConfigs|Types.ProcessDatastoresConfigs - Configuration object containing settings for the batch process
    @return number - 0 on successful completion
]]
return function(guid: string, processName: string, configs: ProcessKeysConfigs | ProcessDatastoresConfigs): number
    print("Info: Starting stage 2 processing")

    -- Initialize global id and configs
    PROCESS_NAME = processName
    CONFIGS = configs

    -- Initialize memory store objects
    local itemPageMapName = "_RBX_batch-process-pages" .. "-" .. PROCESS_NAME
    local failedItemLogsMapName = "_RBX_batch-process-failed-item-logs" .. "-" .. PROCESS_NAME
    local queueName = "_RBX_batch-process-job-queue" .. "-" .. PROCESS_NAME
    itemPageMap = MemoryStoreService:GetSortedMap(itemPageMapName)
    failedItemLogsMap = MemoryStoreService:GetSortedMap(failedItemLogsMapName)
    jobQueue = MemoryStoreService:GetQueue(queueName, 300)
    staggeredTaskExecutor = StaggeredTaskExecutor().new(60 / CONFIGS.processItemRateLimit)
    guidToSessionPathsMap = MemoryStoreService:GetSortedMap(BATCH_PROCESS_GUID_TO_SESSION_PATHS_MAP_NAME)
    storagePoolMap = MemoryStoreService:GetSortedMap(BATCH_PROCESS_STORAGE_POOL_MAP_NAME)

    -- Get the session path and add to the Session Task status map
    SESSION_PATH = getSessionPathAndUpdateStatus(guid)
    print("Info: Loaded session path: " .. SESSION_PATH)

    -- Load the callback function
    processItem = processItemBuilder()

    -- Kick off the processing
    processStage2Async()
    print("Info: Process completed")
    return 0
end
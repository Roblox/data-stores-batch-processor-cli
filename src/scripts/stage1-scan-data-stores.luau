--!strict

--[[
    Stage 1 of the batch processing system. This script scans data stores in an experience. 
    It initializes a batch process, lists data stores into pages, and queues
    them for processing in stage 2.

    This script runs in the engine in Roblox's cloud via Open Cloud Luau Execution
]]

-- Services
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")

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
    maxItemsPerJob: number, -- The maximum number of items in a single job
    jobQueueMaxSize: number, -- The maximum number of jobs on the job queue
    errorLogMaxLength: number, -- The maximum length of the error log
    progressRefreshTimeout: number, -- The timeout for refreshing progress
    memoryStoresExpiration: number, -- The expiration time for memory stores
    memoryStoresStorageLimit: number -- The storage limit for memory stores
}

type ScanDataStoresConfigs = {
    dataStorePrefix: string -- The prefix of the DataStore
}

type ProcessDataStoresConfigs = ExecutionConfigs & ProcessingConfigs & ScanDataStoresConfigs

type BatchProcess = { 
    name: string, -- The name of the batch process
    scanType: string, -- The type of scan being performed
    configs: ProcessDataStoresConfigs, -- The configuration object
    startTime: number, -- The initial start time
    updateTime: number, -- The last update time
    status: string, -- "InProgress", "Failed", or "Done"
    scannedItems: number, -- The total items scanned
    processedItems: number, -- The total items successfully processed
    failedItems: number, -- The total items failed
    nextCursor: string, -- The cursor for the next page to scan
    nextPageIndex: number, -- The index of the next page to scan
    lastCommittedPageIndex: number, -- The index of the last page that was successfully processed
    listingComplete: boolean -- Whether the listing of data stores has been completed
}

type ItemPageInfo = {
    nextCursor: string, -- The cursor for the next page to scan
    createTime: number, -- The time this page was created
    updateTime: number, -- The last time this page was updated
    processedItems: number, -- The total items processed successfully on this page
    failedItems: number, -- The total items failed on this page
    status: string, -- "InProgress" or "Done"
    failedItemsList: { string }, -- The list of failed items
    reservedStorageBytes: number -- The total storage bytes reserved for the page and job
}

type Job = {
    pageIndex: number, -- The index of the page to process
    nextCursor: string, -- The cursor for the next page to scan
    items: { string } -- The list of DataStores to process
}

type StoragePool = {
    bytes: number, -- The total storage bytes for the batch process
    numFailedItemLogs: number, -- The number of failed items since the last update
}

type SortedMapItem = {
    key: string, -- The key of the item
    sortKey: any, -- The sort key of the item
    value: any -- The value of the item
}

type GetRangeBound = {
    key: string, -- The key of the bound
    sortKey: any -- The sort key of the bound
}

type Function = (...any) -> ...any -- A function that takes any number of arguments and returns any number of results
type ProcessCallback = (item: string) -> any -- A function that takes an item and returns anything
type ProtectedFunctionHandler = (Function) -> (boolean, ...any) -- A function that takes a function and returns a boolean and any number of results

-- Constants for batch processing
local BATCH_PROCESS_MAP_NAME = "_RBX_batch-processes" -- The name of the batch process map
local BATCH_PROCESS_GUID_TO_SESSION_PATHS_MAP_NAME = "_RBX_batch-process-guid-to-session-paths"
local BATCH_PROCESS_STORAGE_POOL_MAP_NAME = "_RBX_batch-process-storage-pool"

-- Constants for retry logic
local DEFAULT_RETRY_COUNT = 10
local DEFAULT_RETRY_TIMEOUT_BASE = 0.5
local DEFAULT_RETRY_TIMEOUT_EXPONENTIAL_BACKOFF = 1.5

-- Constants for listing
local PAGES_SORTED_MAP_MAX_SIZE = 200
local GET_RANGE_PAGE_SIZE = 100

-- Constants for storage tracking
local BUFFER_BYTES = 1024 -- Extra 1kb buffer
local BATCH_PROCESS_OVERHEAD_BYTES = 1125 -- Length of the batch process entry
local FAILED_ITEM_LOG_OVERHEAD_BYTES = 209 -- Length of the failed item log without the truncated error log
local TASK_STATUS_OVERHEAD_BYTES = 229 -- Worst case size of the task status entry without the session paths
local SESSION_PATH_BYTES = 161 -- Length of the session path, accounting for quotes
local STORAGE_POOL_OVERHEAD_BYTES = 45 -- Length of the storage bytes entry
local JOB_OVERHEAD_BYTES = 97 -- Length of the job entry
local SESSION_TASK_RATE_LIMIT = 40 -- The number of session tasks that can be spun up in a minute
local BYTES_PER_KILOBYTE = 1024 -- The number of bytes in a kilobyte

-- Global variables
local SESSION_PATH: string -- The Session Path
local PROCESS_NAME: string -- The name of the batch process
local CONFIGS: ProcessDataStoresConfigs -- The configuration object passed to the script
local firstPageOfSession = true 

-- Global references to memory store objects
local batchProcessMap: MemoryStoreSortedMap -- Stores overall batch process state
local itemPageMap: MemoryStoreSortedMap -- Stores individual page processing state
local jobQueue: MemoryStoreQueue -- Batch queue for processing items
local guidToSessionPathsMap: MemoryStoreSortedMap -- Stores a mapping from the id to the session paths
local failedItemLogsMap: MemoryStoreSortedMap -- Stores the failed item logs
local failedItemsOrderedDataStore: OrderedDataStore -- Stores the batch process' failed items
local storagePoolMap: MemoryStoreSortedMap -- Stores the total storage pool in bytes for the batch process

-- Global references to data store objects
local batchProcessDataStoresMap: DataStore -- Stores the batch process backup

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
    Reconciles the total storage for the batch process
]]
local function reconcileStoragePool(): ()
    local newStoragePool = BUFFER_BYTES

    -- Get the estimated size of the batch process entry
    newStoragePool += BATCH_PROCESS_OVERHEAD_BYTES

    -- Get the estimated size of the task status entry
    newStoragePool += TASK_STATUS_OVERHEAD_BYTES
    newStoragePool += CONFIGS.numProcessingInstances * (SESSION_PATH_BYTES + 1)

    -- Get the estimated size of the guid to session paths map
    newStoragePool += math.min(CONFIGS.numProcessingInstances, SESSION_TASK_RATE_LIMIT) * SESSION_PATH_BYTES

    -- Get the total storage bytes for the pages map and job
    local exclusiveLowerBound: GetRangeBound? = nil
    while true do
        local getItemPagesSuccess: boolean, getItemPagesResult: { SortedMapItem } | string = retryAsync(function()
            return itemPageMap:GetRangeAsync(Enum.SortDirection.Ascending, GET_RANGE_PAGE_SIZE, exclusiveLowerBound)
        end)
        if not getItemPagesSuccess then
            error("Error: Failed to get item pages. Reason - " .. getItemPagesResult :: string)
        end

        local pages = getItemPagesResult :: { SortedMapItem }
        for _, itemPage in ipairs(pages) do
            local itemPageInfo = itemPage.value :: ItemPageInfo
            newStoragePool += itemPageInfo.reservedStorageBytes
        end

        if #pages < GET_RANGE_PAGE_SIZE then
            break
        end

        exclusiveLowerBound = {
            key = pages[#pages].key,
            sortKey = pages[#pages].sortKey
        }
    end

    -- Get the total storage bytes for the failed items sorted map
    local getFailedItemLogsSizeSuccess: boolean, getFailedItemLogsSizeResult: number | string = retryAsync(function()
        return failedItemLogsMap:GetSizeAsync()
    end)
    if not getFailedItemLogsSizeSuccess then
        error("Error: Failed to get failed items ordered data store size. Reason - " .. getFailedItemLogsSizeResult :: string)
    end
    local failedItemLogsSize = getFailedItemLogsSizeResult :: number
    newStoragePool += failedItemLogsSize * (FAILED_ITEM_LOG_OVERHEAD_BYTES + CONFIGS.errorLogMaxLength)

    -- Add the size of the storage bytes entry
    newStoragePool += STORAGE_POOL_OVERHEAD_BYTES

    -- Update the storage bytes map
    local updateStoragePoolSuccess: boolean, updateStoragePoolResult: string = retryAsync(function()
        return storagePoolMap:UpdateAsync(PROCESS_NAME, function(currentStoragePool: StoragePool?)
            if currentStoragePool then
                currentStoragePool.bytes = newStoragePool
                currentStoragePool.numFailedItemLogs = failedItemLogsSize
            else
                currentStoragePool = {
                    bytes = newStoragePool,
                    numFailedItemLogs = failedItemLogsSize
                }
            end
            return currentStoragePool
        end, CONFIGS.memoryStoresExpiration)
    end)
    if not updateStoragePoolSuccess then
        error("Error: Failed to update storage bytes. Reason - " .. updateStoragePoolResult)
    end

    print("Info: Reconciled storage pool. Current size: " .. newStoragePool .. " bytes.")
end

--[[
    Reconciles the failed item log bytes
]]
local function reconcileFailedItemLogsBytes(): ()
    -- Get the total number of failed item logs
    local getFailedItemLogsSuccess: boolean, getFailedItemLogsResult: number | string = retryAsync(function()
        return failedItemLogsMap:GetSizeAsync()
    end)
    if not getFailedItemLogsSuccess then
        error("Error: Failed to get failed items ordered data store size. Reason - " .. getFailedItemLogsResult :: string)
    end
    local failedItemLogsMapSize = getFailedItemLogsResult :: number

    -- Correct the storage bytes map with the difference in failed item logs
    local updateStoragePoolSuccess: boolean, updateStoragePoolResult: string | StoragePool = retryAsync(function()
        return storagePoolMap:UpdateAsync(PROCESS_NAME, function(currentStoragePool: StoragePool)
            local numFailedItemLogs = currentStoragePool.numFailedItemLogs
            currentStoragePool.numFailedItemLogs = failedItemLogsMapSize
            currentStoragePool.bytes += (failedItemLogsMapSize - numFailedItemLogs) * (FAILED_ITEM_LOG_OVERHEAD_BYTES + CONFIGS.errorLogMaxLength)
            return currentStoragePool
        end, CONFIGS.memoryStoresExpiration)
    end)
    if not updateStoragePoolSuccess then
        error("Error: Failed to update storage bytes. Reason - " .. updateStoragePoolResult :: string)
    end

    local currentStoragePool = updateStoragePoolResult :: StoragePool
    print("Info: Current memory stores storage pool size: " .. currentStoragePool.bytes .. " bytes.")
end

--[[
    Initializes a new batch process with default state
]]
local function initializeNewBatchProcess(): ()
    local startTime = DateTime.now().UnixTimestamp
    local newProcessInfo: BatchProcess = {
        name = PROCESS_NAME,
        scanType = "data-stores",
        configs = CONFIGS, 
        startTime = startTime, 
        updateTime = startTime, 
        status = "InProgress",
        scannedItems = 0, 
        processedItems = 0,
        failedItems = 0, 
        nextCursor = "", 
        nextPageIndex = 0, 
        lastCommittedPageIndex = -1,
        listingComplete = false
    }

    local setBatchProcessSuccess: boolean, setBatchProcessResult: string = retryAsync(function()
        return batchProcessMap:SetAsync(PROCESS_NAME, newProcessInfo, CONFIGS.memoryStoresExpiration)
    end)
    if not setBatchProcessSuccess then
        error("Error: Failed to initialize batch process. Reason - " .. setBatchProcessResult :: string)
    end

    -- Backup the batch process to data stores
    local setBatchProcessDataStoreBackupSuccess: boolean, setBatchProcessDataStoreBackupResult: string = retryAsync(function()
        return batchProcessDataStoresMap:SetAsync(PROCESS_NAME, newProcessInfo)
    end)
    if not setBatchProcessDataStoreBackupSuccess then
        error("Error: Failed to initialize batch process. Reason - " .. setBatchProcessDataStoreBackupResult :: string)
    end
end

--[[
    Initializes or loads a batch process
]]
local function initializeBatchProcess(): ()
    -- Load the existing batch process if it exists
    local getBatchProcessSuccess: boolean, getBatchProcessResult: BatchProcess? | string = retryAsync(function()
        return batchProcessMap:GetAsync(PROCESS_NAME)
    end)
    if not getBatchProcessSuccess then
        -- If this fails, the CLI will restart the stage 1 script at a later time
        error("Error: Failed to get batch process. Reason - " .. getBatchProcessResult :: string)
    end

    local existingProcessInfo = getBatchProcessResult :: BatchProcess?
    if not existingProcessInfo then
        -- If the process does not exist, we can create a new one
        initializeNewBatchProcess()
        return
    end

    -- If the process is not done, we can resume it
    if existingProcessInfo.status ~= "Done" then
        print("Info: Batch process was not completed. Resuming from last state.")
    else
        error("Error: Batch process cannot be restarted from state - " .. existingProcessInfo.status)
    end

    -- Update process status with new update time
    local updateBatchProcessSuccess: boolean, updateBatchProcessResult: string = retryAsync(function()
        return batchProcessMap:UpdateAsync(PROCESS_NAME, function(currentProcessInfo: BatchProcess)
            currentProcessInfo.status = "InProgress"
            currentProcessInfo.updateTime = DateTime.now().UnixTimestamp
            currentProcessInfo.configs = CONFIGS
            return currentProcessInfo
        end, CONFIGS.memoryStoresExpiration)
    end)
    if not updateBatchProcessSuccess then
        error("Error: Failed to update batch process. Reason - " .. updateBatchProcessResult)
    end
end

--[[
    Creates a single page of Data Stores and queues it for stage 2 processing
    @param dataStores { DataStoreInfo } - List of DataStore objects to process
    @param pageIndex number - Current page index
    @param nextCursor string - Cursor for paginating the next page
    @return boolean - Whether the page was created
]]
local function createDataStorePage(dataStores: { DataStoreInfo }, pageIndex: number, nextCursor: string): boolean
    -- Extract DataStore names for processing
    local itemsStorageBytes = 0
    local dataStoreNames: { string } = {}
    for _, dataStore in ipairs(dataStores) do
        table.insert(dataStoreNames, dataStore.DataStoreName)
        itemsStorageBytes += (string.len(dataStore.DataStoreName) + 3)
    end
    itemsStorageBytes -= 1

    -- Stage item page entry
    local itemPageKey = PROCESS_NAME .. "-" .. pageIndex
    local itemPageInfo: ItemPageInfo = {
        nextCursor = nextCursor, 
        createTime = DateTime.now().UnixTimestamp, 
        updateTime = DateTime.now().UnixTimestamp, 
        processedItems = 0, 
        failedItems = 0, 
        status = "InProgress",
        failedItemsList = {},
        reservedStorageBytes = 0
    }

    -- Try to get the old item page info if this is the first list of the session
    local oldItemPageInfo: ItemPageInfo? = nil
    if firstPageOfSession then
        local getItemPageSuccess: boolean, getItemPageResult: ItemPageInfo? | string = retryAsync(function()
            return itemPageMap:GetAsync(itemPageKey)
        end)
        if not getItemPageSuccess then
            error("Error: Failed to get item page. Reason - " .. getItemPageResult :: string)
        end
        oldItemPageInfo = getItemPageResult :: ItemPageInfo?
    end

    -- Calculate the reserved storage bytes for the item page entry and job
    local jobBytes = JOB_OVERHEAD_BYTES + itemsStorageBytes
    itemPageInfo.reservedStorageBytes = jobBytes + itemsStorageBytes
    itemPageInfo.reservedStorageBytes += string.len(HttpService:JSONEncode(itemPageInfo))

    -- If the item page entry already exists, correct the reserved storage bytes, assuming the old job was added to the queue
    if oldItemPageInfo then
        local itemsStorageBytesDiff = (itemPageInfo.reservedStorageBytes - oldItemPageInfo.reservedStorageBytes) / 2
        itemPageInfo.reservedStorageBytes = oldItemPageInfo.reservedStorageBytes + jobBytes + itemsStorageBytesDiff -- corrects the reserved storage for the item page, and accounts for the new job
    end

    -- Try to reserve the extra storage for the item page entry and job
    local storageBytesSuccess: boolean, storageBytesResult: boolean | string = retryAsync(function()
        -- Store a boolean to check if the storage limit is exceeded, so we can log a warning after we try to reserve the storage
        local exceedsStorageLimit = false
        storagePoolMap:UpdateAsync(PROCESS_NAME, function(currentStoragePool: StoragePool)
            currentStoragePool.bytes += itemPageInfo.reservedStorageBytes
            if oldItemPageInfo then
                currentStoragePool.bytes -= oldItemPageInfo.reservedStorageBytes
            end
            if currentStoragePool.bytes > CONFIGS.memoryStoresStorageLimit * BYTES_PER_KILOBYTE then
                exceedsStorageLimit = true
                return nil
            end
            return currentStoragePool
        end, CONFIGS.memoryStoresExpiration)
        return exceedsStorageLimit
    end)
    if not storageBytesSuccess then
        print("Warning: Failed to update storage pool. Reason - " .. storageBytesResult :: string)
        return false
    end

    -- If the storage limit is exceeded, we can't create the item page entry
    local exceedsStorageLimit = storageBytesResult :: boolean
    if exceedsStorageLimit then
        print("Warning: Not enough storage bytes to allot for item page entry and job. Skipping for now.")
        return false
    end

    -- Create the item page entry
    local createDataStorePageSuccess: boolean, createDataStorePageResult: string = retryAsync(function()
        itemPageMap:SetAsync(itemPageKey, itemPageInfo, CONFIGS.memoryStoresExpiration)
    end)
    if not createDataStorePageSuccess then
        error("Error: Failed to create data store page. Reason - " .. createDataStorePageResult)
    end

    -- Queue batch for stage 2 processing
    local job: Job = {
        pageIndex = pageIndex,
        nextCursor = nextCursor,
        items = dataStoreNames
    }
    local addJobSuccess: boolean, addJobResult: string = retryAsync(function()
        jobQueue:AddAsync(job, CONFIGS.memoryStoresExpiration)
    end)
    if not addJobSuccess then
        error("Error: Failed to add batch to queue. Reason - " .. addJobResult)
    end
    print("Info: Created data store page " .. itemPageKey .. " and added job to queue")

    -- Update overall batch process state
    local updateBatchProcessSuccess: boolean, updateBatchProcessResult: BatchProcess | string = retryAsync(function()
        return batchProcessMap:UpdateAsync(PROCESS_NAME, function(currentProcessInfo: BatchProcess)
            currentProcessInfo.nextPageIndex = pageIndex + 1
            currentProcessInfo.nextCursor = nextCursor
            currentProcessInfo.scannedItems += #dataStores
            currentProcessInfo.updateTime = DateTime.now().UnixTimestamp
            return currentProcessInfo
        end, CONFIGS.memoryStoresExpiration)
    end)
    if not updateBatchProcessSuccess then
        error("Error: Failed to update batch process. Reason - " .. updateBatchProcessResult :: string)
    end

    firstPageOfSession = false

    return true
end

--[[
    Checks if listing pages should continue
    @param listingComplete boolean - Whether the listing is complete
    @param pagesListed number - The number of pages listed so far
    @return boolean - Whether the listing should continue
]]
local function shouldContinueListing(listingComplete: boolean, pagesListed: number): boolean
    -- Check if the listing is complete
    if listingComplete then
        return false
    end

    -- Check if the number of pages listed has reached the maximum
    if pagesListed >= CONFIGS.jobQueueMaxSize then
        return false
    end

    -- Check if the job queue size has reached the maximum
    local getJobQueueSizeSuccess: boolean, getJobQueueSizeResult: number | string = retryAsync(function()
        return jobQueue:GetSizeAsync()
    end)
    if not getJobQueueSizeSuccess then
        error("Error: Failed to get job queue size. Reason - " .. getJobQueueSizeResult :: string)
    end
    local jobQueueSize = getJobQueueSizeResult :: number
    if jobQueueSize >= CONFIGS.jobQueueMaxSize then
        return false
    end

    -- Check if the pages sorted map size has reached the maximum
    local getPagesSortedMapSizeSuccess: boolean, getPagesSortedMapSizeResult: number | string = retryAsync(function()
        return itemPageMap:GetSizeAsync()
    end)
    if not getPagesSortedMapSizeSuccess then
        error("Error: Failed to get pages sorted map size. Reason - " .. getPagesSortedMapSizeResult :: string)
    end
    local pagesSortedMapSize = getPagesSortedMapSizeResult :: number
    if pagesSortedMapSize >= PAGES_SORTED_MAP_MAX_SIZE then
        return false
    end

    return true
end

--[[
    Lists pages of DataStores
    @return boolean - Whether the listing is complete
]]
local function listPages(): boolean

    -- Load the current listing state
    local getBatchProcessSuccess: boolean, getBatchProcessResult: BatchProcess | string = retryAsync(function()
        return batchProcessMap:GetAsync(PROCESS_NAME)
    end)
    if not getBatchProcessSuccess then
        error("Error: Failed to get batch process. Reason - " .. getBatchProcessResult :: string)
    end

    local processInfo = getBatchProcessResult :: BatchProcess
    local cursor: string = processInfo.nextCursor
    local pageIndex: number = processInfo.nextPageIndex

    local listingComplete = processInfo.listingComplete

    local pagesListed = 0
    while shouldContinueListing(listingComplete, pagesListed) do
        -- List DataStores with the current cursor
        local listDataStoresSuccess: boolean, listDataStoresResult: DataStoreListingPages | string = pcall(function()
            return DataStoreService:ListDataStoresAsync(CONFIGS.dataStorePrefix, CONFIGS.maxItemsPerJob, cursor)
        end)
        if not listDataStoresSuccess then
            break
        end
        pagesListed += 1

        -- Create a page of DataStores for processing
        local pages = listDataStoresResult :: DataStoreListingPages
        local dataStores: { DataStoreInfo } = pages:GetCurrentPage()
        local createdPage = createDataStorePage(dataStores, pageIndex, pages.Cursor)
        if not createdPage then
            break
        end

        -- Iterate to next page 
        cursor = pages.Cursor
        listingComplete = cursor == ""
        pageIndex += 1
    end

    -- Update the batch process listing completed state
    if listingComplete then
        local updateBatchProcessSuccess: boolean, updateBatchProcessResult: string = retryAsync(function()
            return batchProcessMap:UpdateAsync(PROCESS_NAME, function(currentProcessInfo: BatchProcess)
                currentProcessInfo.listingComplete = true
                return currentProcessInfo
            end, CONFIGS.memoryStoresExpiration)
        end)
        if not updateBatchProcessSuccess then
            error("Error: Failed to update batch process. Reason - " .. updateBatchProcessResult)
        end
    end	

    return listingComplete
end

--[[
    Processes completed item pages and updates batch process state
    @return boolean - Whether there are remaining pages to process
]]
local function processCompletedPages(): boolean
    -- Load the current page processing state
    local getBatchProcessSuccess: boolean, getBatchProcessResult: BatchProcess | string = retryAsync(function()
        return batchProcessMap:GetAsync(PROCESS_NAME)
    end)
    if not getBatchProcessSuccess then
        error("Error: Failed to get batch process. Reason - " .. getBatchProcessResult :: string)
    end

    local processInfo = getBatchProcessResult :: BatchProcess
    local lastCommittedIndex: number = processInfo.lastCommittedPageIndex

    -- Clean up the last committed page
    if lastCommittedIndex >= 0 then
        local lastPageKey = PROCESS_NAME .. "-" .. lastCommittedIndex
        local removePageSuccess: boolean, removePageResult: string = retryAsync(function()
            itemPageMap:RemoveAsync(lastPageKey)
        end)
        if not removePageSuccess then
            error("Error: Failed to remove page. Reason - " .. lastPageKey .. ": " .. removePageResult)
        end
    end

    -- Process all item pages
    local hasRemainingPages = false
    local exclusiveLowerBound: GetRangeBound? = nil
    while true do
        local getItemPagesSuccess: boolean, getItemPagesResult: { SortedMapItem } | string = retryAsync(function()
            return itemPageMap:GetRangeAsync(Enum.SortDirection.Ascending, GET_RANGE_PAGE_SIZE, exclusiveLowerBound)
        end)
        if not getItemPagesSuccess then
            error("Error: Failed to get item pages. Reason - " .. getItemPagesResult :: string)
        end

        local pages = getItemPagesResult :: { SortedMapItem }
        for _, itemPage in ipairs(pages) do
            if itemPage.value.status == "Done" then
                print("Info: Page " .. itemPage.key .. " complete - updated batch process info")

                -- Extract and process page index
                local pageIndex = tonumber(itemPage.key:match("%-(%d+)$"))
                if pageIndex then

                    -- Add failed items to the failed items ordered data store with the timestamp as the value
                    for _, failedItem in ipairs(itemPage.value.failedItemsList) do
                        local addFailedItemSuccess: boolean, addFailedItemResult: string = retryAsync(function()
                            failedItemsOrderedDataStore:SetAsync(failedItem, DateTime.now().UnixTimestampMillis)
                        end)
                        if not addFailedItemSuccess then
                            error("Error: Failed to add failed item to failed items ordered data store. Reason - " .. addFailedItemResult)
                        end
                    end

                    -- Update batch process statistics
                    local updateBatchProcessInfoSuccess: boolean, updateBatchProcessInfoResult: string = retryAsync(function()
                        batchProcessMap:UpdateAsync(PROCESS_NAME, function(currentProcessInfo: BatchProcess)
                            currentProcessInfo.processedItems += itemPage.value.processedItems
                            currentProcessInfo.failedItems += itemPage.value.failedItems
                            currentProcessInfo.lastCommittedPageIndex = pageIndex
                            currentProcessInfo.updateTime = DateTime.now().UnixTimestamp
                            return currentProcessInfo
                        end, CONFIGS.memoryStoresExpiration)
                    end)
                    if not updateBatchProcessInfoSuccess then
                        error("Error: Failed to update batch process info for page" .. itemPage.key .. ". Reason - " .. updateBatchProcessInfoResult)
                    end

                    -- Clean up completed page
                    local removePageSuccess: boolean, removePageResult: string = retryAsync(function()
                        itemPageMap:RemoveAsync(itemPage.key)
                    end)
                    if not removePageSuccess then
                        error("Error: Failed to remove page with index" .. itemPage.key .. ". Reason - " .. removePageResult)
                    end

                    -- Return storage to the pool
                    local returnStorageToPoolSuccess: boolean, returnStorageToPoolResult: string = retryAsync(function()
                        storagePoolMap:UpdateAsync(PROCESS_NAME, function(currentStoragePool: StoragePool)
                            currentStoragePool.bytes -= itemPage.value.reservedStorageBytes
                            return currentStoragePool
                        end, CONFIGS.memoryStoresExpiration)
                    end)
                    if not returnStorageToPoolSuccess then
                        error("Error: Failed to return storage to pool. Reason - " .. returnStorageToPoolResult)
                    end
                else
                    error("Error: Failed to get page index for page " .. itemPage.key .. ". Please ensure you are not writing to this protected memory store.")
                end
            else
                hasRemainingPages = true
            end
        end

        if #pages < GET_RANGE_PAGE_SIZE then
            break
        end

        exclusiveLowerBound = {
            key = pages[#pages].key,
            sortKey = pages[#pages].sortKey
        }
    end

    return hasRemainingPages
end

--[[
    Gets the session path from the guid to session paths map
    @param id string - The id of the batch process
    @return string - The session path
]]
local function getSessionPath(id: string): string
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
    Main stage 1 processing function that:
    1. Initializes the batch process
    2. Lists all Data Stores into the job queue
    3. Monitors completion of processing
    This is an async function that handles the entire stage 1 workflow
]]
local function processStage1Async(): ()
    -- Initialize batch process state
    initializeBatchProcess()
    print("Info: Initialized batch process")

    -- Reconcile storage bytes
    reconcileStoragePool()

    -- List and process completed pages until all are done
    local batchProcessSuccess = false
    local listingComplete = false
    while true do
        -- Fill the batch queue with pages
        if not listingComplete then
            listingComplete = listPages()
        end

        -- Process pages for completion
        local hasRemainingPages: boolean = processCompletedPages()

        -- Ensure we have not passed the failed item threshold
        local getBatchProcessSuccess: boolean, getBatchProcessResult: BatchProcess | string = retryAsync(function()
            return batchProcessMap:GetAsync(PROCESS_NAME)
        end)
        if not getBatchProcessSuccess then
            error("Error: Failed to get batch process. Reason - " .. getBatchProcessResult :: string)
        end
        local processInfo = getBatchProcessResult :: BatchProcess
        if processInfo.failedItems >= CONFIGS.maxTotalFailedItems then
            print("Warning: Failed item threshold reached")
            break
        end

        -- Check if the batch process is stopped
        if processInfo.status == "Stopped" then
            print("Info: Batch process is stopped")
            break
        end

        -- All processing is complete
        if not hasRemainingPages and listingComplete then
            print("Info: All processing is complete")
            batchProcessSuccess = true
            break
        end

        -- Update the batch process update time
        local updateBatchProcessSuccess: boolean, updateBatchProcessResult: BatchProcess | string = retryAsync(function()
            return batchProcessMap:UpdateAsync(PROCESS_NAME, function(currentProcessInfo: BatchProcess)
                currentProcessInfo.updateTime = DateTime.now().UnixTimestamp
                return currentProcessInfo
            end, CONFIGS.memoryStoresExpiration)
        end)
        if not updateBatchProcessSuccess then
            error("Error: Failed to update batch process. Reason - " .. updateBatchProcessResult :: string)
        end

        -- Reconcile the failed item log bytes
        reconcileFailedItemLogsBytes()

        -- Backup the batch process to data stores - only try this once as it is non-essential
        local success: boolean = pcall(function()
            batchProcessDataStoresMap:SetAsync(PROCESS_NAME, processInfo)
        end)
        if success then
            print("Info: Backed up the batch process to data stores")
        else
            print("Warning: Failed to backup the batch process to data stores")
        end

        -- Timeout before next iteration
        print("Info: Waiting for " .. CONFIGS.progressRefreshTimeout .. " seconds before next iteration")
        task.wait(CONFIGS.progressRefreshTimeout)
    end

    -- Update the processing status
    local updateBatchProcessSuccess: boolean, updateBatchProcessResult: BatchProcess | string = retryAsync(function()
        return batchProcessMap:UpdateAsync(PROCESS_NAME, function(currentProcessInfo: BatchProcess)
            if currentProcessInfo.status ~= "Stopped" then
                currentProcessInfo.status = batchProcessSuccess and "Done" or "Failed"
            end
            currentProcessInfo.updateTime = DateTime.now().UnixTimestamp
            return currentProcessInfo
        end, CONFIGS.memoryStoresExpiration)
    end)
    if not updateBatchProcessSuccess then
        error("Error: Failed to update batch process. Reason - " .. updateBatchProcessResult :: string)
    end
    print("Info: Updated batch process status as " .. (updateBatchProcessResult :: BatchProcess).status)
    local processInfo = updateBatchProcessResult :: BatchProcess

    -- Backup the batch process to data stores with the correct final state
    local backupDataStoresSuccess: boolean, backupDataStoresResult: string = retryAsync(function()
        batchProcessDataStoresMap:SetAsync(PROCESS_NAME, processInfo)
    end)
    if backupDataStoresSuccess then
        print("Info: Backed up the batch process to data stores")
    else
        error("Error: Failed to backup the batch process to data stores. Reason - " .. backupDataStoresResult :: string)
    end

    -- Signal EOF to all processing instances
    for i = 1, CONFIGS.numProcessingInstances do
        local enqueueEOFSuccess: boolean, enqueueEOFResult: string = retryAsync(function()
            jobQueue:AddAsync("EOF", CONFIGS.memoryStoresExpiration, 1)
        end)
        if not enqueueEOFSuccess then
            error("Error: Failed to enqueue EOF for processing instance " .. i .. ". Reason - " .. enqueueEOFResult)
        end
    end
end

--[[
    Main entry point for the batch processing script
    @param guid string - The CLI-generated guid of the batch process
    @param processName string - Name of the batch process
    @param configs Types.ProcessDataStoresConfigs - Configuration object containing settings for the batch process
    @return number - 0 on successful completion
]]
return function(guid: string, processName: string, configs: ProcessDataStoresConfigs): number
    print("Info: Starting stage 1 processing")

    -- Initialize process name and global configs
    PROCESS_NAME = processName
    CONFIGS = configs

    -- Initialize memory store objects
    local itemPageMapName = "_RBX_batch-process-pages" .. "-" .. PROCESS_NAME
    local queueName = "_RBX_batch-process-job-queue" .. "-" .. PROCESS_NAME
    local failedItemLogsMapName = "_RBX_batch-process-failed-item-logs" .. "-" .. PROCESS_NAME
    local failedItemsOrderedDataStoreName = "_RBX_batch-process-failed-items" .. "-" .. PROCESS_NAME
    batchProcessMap = MemoryStoreService:GetSortedMap(BATCH_PROCESS_MAP_NAME)
    itemPageMap = MemoryStoreService:GetSortedMap(itemPageMapName)
    jobQueue = MemoryStoreService:GetQueue(queueName, 300)
    failedItemLogsMap = MemoryStoreService:GetSortedMap(failedItemLogsMapName)
    failedItemsOrderedDataStore = DataStoreService:GetOrderedDataStore(failedItemsOrderedDataStoreName)
    guidToSessionPathsMap = MemoryStoreService:GetSortedMap(BATCH_PROCESS_GUID_TO_SESSION_PATHS_MAP_NAME)
    storagePoolMap = MemoryStoreService:GetSortedMap(BATCH_PROCESS_STORAGE_POOL_MAP_NAME)
    batchProcessDataStoresMap = DataStoreService:GetDataStore(BATCH_PROCESS_MAP_NAME)

    -- Get the session path
    SESSION_PATH = getSessionPath(guid)
    print("Info: Loaded session path: " .. SESSION_PATH)

    -- Kick off the scan process
    processStage1Async()
    print("Info: Process completed")
    return 0
end
--!strict

--[[
    Common type definitions used throughout the codebase.
    These types define the structure of configuration objects and command parameters.
]]

--[[
    Configuration flag type.
    Represents a command line flag with optional inverse flag.
]]
export type ConfigFlag = {
    flag: string, -- The flag string
    flagInverse: string?, -- The inverse flag string
    description: string, -- The description of the flag
    descriptionInverse: string?, -- The description of the inverse flag
    prompt: string?, -- The prompt to display when asking for the config
    override: string? -- The config that is overridden by this flag
}

--[[
    Configuration option type.
    Represents a command line option with optional short form.
]]
export type ConfigOption = {
    option: string, -- The option string
    shortOption: string?, -- The short option string
    description: string, -- The description of the option
    default: any?, -- The default value of the option
    prompt: string? -- The prompt to display when asking for the config
}

--[[
    Configuration values type.
    Maps configuration keys to their values.
]]
export type ConfigValues = { [string]: any }

--[[
    Execution configuration type.
    Contains parameters for batch processing execution.
]]
export type ExecutionConfigs = {
    universeId: string, -- The universe ID
    placeId: string, -- The place ID
    callback: string, -- The callback function filepath
    numProcessingInstances: number, -- The number of processing instances to run
    outputDirectory: string, -- The output directory
}

--[[
    Processing configuration type.
    Contains parameters for batch processing behavior.
]]
export type ProcessingConfigs = {
    processItemRateLimit: number, -- The rate limit for processing items
    numRetries: number, -- The number of retries before failing items
    retryTimeoutBase: number, -- The base timeout for retries
    retryExponentialBackoff: number, -- The exponential backoff for retries
    maxTotalFailedItems: number, -- The maximum number of failed items before failing a batch process
    maxItemsPerjob: number, -- The maximum number of items in a single task
    jobQueueMaxSize: number, -- The maximum number of tasks on the task queue
    errorLogMaxLength: number, -- The maximum length of the error log
    progressRefreshTimeout: number, -- The timeout for refreshing progress
    memoryStoresExpiration: number, -- The expiration time for memory stores
    memoryStoresStorageLimit: number -- The storage limit for memory stores
}

--[[
    Scan keys configuration type.
    Contains parameters for scanning DataStore keys.
]]
export type ScanKeysConfigs = { 
    dataStoreName: string, -- The name of the DataStore
    allScopes: boolean, -- Whether to process all scopes
    dataStoreScope: string, -- The scope of the DataStore
    keyPrefix: string, -- The prefix of the keys to process
    excludeDeletedKeys: boolean -- Whether to exclude deleted keys
}

--[[
    Scan DataStores configuration type.
    Contains parameters for scanning DataStores.
]]
export type ScanDatastoresConfigs = {
    dataStorePrefix: string -- The prefix of the DataStore
}

--[[
    Resume configuration type.
]]
export type ResumeConfigs = {
    universeId: string,
    outputDirectory: string,
    numProcessingInstances: number,
    processItemRateLimit: number,
    numRetries: number,
    retryTimeoutBase: number,
    retryExponentialBackoff: number,
    maxTotalFailedItems: number,
    jobQueueMaxSize: number,
    errorLogMaxLength: number,
    progressRefreshTimeout: number,
    memoryStoresExpiration: number,
    memoryStoresStorageLimit: number
}

--[[
    Cleanup configuration type.
]]
export type CleanupConfigs = {
    universeId: string
}

--[[
    List configuration type.
]]
export type ListConfigs = {
    universeId: string
}

-- Combined configuration types
export type ProcessKeysConfigs = ExecutionConfigs & ProcessingConfigs & ScanKeysConfigs
export type ProcessDataStoresConfigs = ExecutionConfigs & ProcessingConfigs & ScanDatastoresConfigs
export type AnyConfigs = ProcessKeysConfigs | ProcessDataStoresConfigs

-- String type definitions
export type CommandType = "process-keys" | "process-data-stores" | "resume" | "cleanup" | "list"
export type ScanType = "keys" | "data-stores"
export type StageType = "stage1" | "stage2"

--[[
    Batch process type.
]]
export type BatchProcess = { 
    name: string, -- The name of the batch process
    scanType: ScanType, -- The type of scan being performed
    configs: AnyConfigs, -- The configuration object
    startTime: number, -- The initial start time
    updateTime: number, -- The last update time
    status: string, -- "InProgress", "Failed", or "Done"
    scannedItems: number, -- The total items scanned
    processedItems: number, -- The total items successfully processed
    failedItems: number, -- The total items failed
    nextCursor: string, -- The cursor for the next page to scan
    nextPageIndex: number, -- The index of the next page to scan
    lastCommittedPageIndex: number, -- The cursor of the last page that was successfully processed
    listingComplete: boolean -- Whether the listing is done
}

--[[
    Failed item type.
]]
export type FailedItem = {
    sessionPath: string, -- The session path of the failed item
    error: string, -- The error message
    time: number -- The time the item failed
}

--[[
    Session task status type.
]]
export type ProcessTaskStatus = {
    numInstances: number | string,
    stage1SessionPaths: { string },
    stage2SessionPaths: { string },
}

--[[
    OpenCloud response structure.
]]
export type OpenCloudResponse = {
    status: number,
    body: any
}

--[[
    Function Types
]]
export type Function = (...any) -> ...any -- A function that takes any number of arguments and returns any number of results
export type ProtectedFunctionHandler = (Function) -> (boolean, ...any) -- A function that takes a function and returns a boolean and any number of results

return {}

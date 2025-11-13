--!strict

--[[
    Constants used throughout the codebase.
]]

-- Local Libraries
local Types = require('./types')

-- Constants
local ActiveStage1TasksFile = "stage1_session_paths_active.output" -- The output file that contains the active stage 1 session paths
local ActiveStage2TasksFile = "stage2_session_paths_active.output" -- The output file that contains the active stage 2 session paths
local BatchProcessFile = "process.output" -- The output file that contains the batch process table
local BatchProcessFailedItemsOrderedDataStorePrefix = "_RBX_batch-process-failed-items-" -- The prefix for the failed items ordered data store
local BatchProcessFailedItemLogsMapPrefix = "_RBX_batch-process-failed-item-logs-" -- The prefix for the failed item logs map
local BatchProcessGuidToSessionPathsMapName = "_RBX_batch-process-guid-to-session-paths" -- The name of the map that contains the guid-session path mapping
local BatchProcessMapName = "_RBX_batch-processes" -- The name of the map that contains the batch processes
local BatchProcessTaskStatusMapName = "_RBX_batch-process-task-status" -- The name of the map that contains the Process Task status
local CLILogFile = "cli.output" -- The output file that contains the CLI logs
local CompletedStage1TasksFile = "stage1_session_paths_complete.output" -- The output file that contains the completed stage 1 session paths
local CompletedStage2TasksFile = "stage2_session_paths_complete.output" -- The output file that contains the completed stage 2 session paths
local FailedItemsFile = "failed_items.output" -- The output file that contains the failed items
local GuidToSessionPathsMapExpiration = 60 -- 1 minute expiration for the guid to session paths map
local PlaceHolder = "\x01" -- A placeholder value for a config that signifies that the config was not provided via the config file or command line arguments
local SessionLogsDirectory = "session_logs" -- The directory that contains the session logs
local TableColumnWidth = 23 -- The number of spaces in each column of the table

--[[
    Command type mappings.
    Maps command names to their string identifiers.
]]
local Commands: { [string]: Types.CommandType } = {
    ["ProcessDataStores"] = "process-data-stores",
    ["ProcessKeys"] = "process-keys",
    ["Resume"] = "resume",
    ["Cleanup"] = "cleanup",
    ["List"] = "list"
}

--[[
    Scan type mappings.
    Maps scan type names to their string identifiers.
]]
local ScanTypes: { [string]: Types.ScanType } = { 
    ["DataStores"] = "data-stores",
    ["Keys"] = "keys"
}

--[[
    Stage type mappings.
    Maps stage type names to their string identifiers.
]]
local StageTypes: { [string]: Types.StageType } = {
    ["Stage1"] = "stage1",
    ["Stage2"] = "stage2"
}


--[[
    Retry configuration for session tasks.
]]
local SessionTaskRetryConfig: { [string]: number } = {
    ["MaxAttempts"] = 3,
    ["TimeoutBase"] = 0.5,
    ["TimeoutExponentialBackoff"] = 2
}

--[[
    List of configuration options.
    Defines all command line options for the application.
]]
local ConfigurationOptions: { [string]: Types.ConfigOption } = {
    -- Execution options
    callback = {
        option = "callback",
        shortOption = "-C",
        description = "Filepath to the callback function to process items",
        prompt = "Enter a filepath for 'callback': "
    },
    numProcessingInstances = {
        option = "num-processing-instances",
        shortOption = "-i",
        description = "Number of stage 2 processing instances to use",
        prompt = "Enter a value for 'numProcessingInstances': "
    },
    outputDirectory = {
        option = "output-directory",
        shortOption = "-o",
        description = "Directory for output files",
        prompt = "Enter a directory filepath for 'outputDirectory' (default: 'output/'): "
    },
    placeId = {
        option = "place-id",
        shortOption = "-p",
        description = "The place ID",
        prompt = "Enter a value for 'placeId': "
    },
    universeId = {
        option = "universe-id",
        shortOption = "-u",
        description = "The universe ID",
        prompt = "Enter a value for 'universeId': "
    },

    -- Processing options
    errorLogMaxLength = {
        option = "error-log-max-length",
        description = "Maximum length of error logs",
        default = 50
    },
    jobQueueMaxSize = {
        option = "job-queue-max-size",
        description = "Maximum size of the job queue",
        default = 20
    },
    maxItemsPerJob = {
        option = "max-items-per-job",
        description = "Maximum items to process in one job",
        default = 50
    },
    maxTotalFailedItems = {
        option = "max-total-failed-items",
        description = "Maximum number of failed items before failing the entire batch process",
        default = 100
    },
    memoryStoresExpiration = {
        option = "memory-stores-expiration",
        description = "Expiration time for memory stores (in seconds)",
        default = 3888000
    },
    memoryStoresStorageLimit = {
        option = "memory-stores-storage-limit",
        description = "Storage limit for memory stores (in kilobytes) (-1 for no limit)",
        default = -1
    },
    numRetries = {
        option = "num-retries",
        description = "Number of times to retry processing an item (choose 0 for no retries)",
        default = 4
    },
    processItemRateLimit = {
        option = "process-item-rate-limit",
        description = "Rate limit for processing items on a single instance (per second)",
        default = 50
    },
    progressRefreshTimeout = {
        option = "progress-refresh-timeout",
        description = "Timeout for refreshing progress (in seconds) for stage 1",
        default = 5
    },
    retryExponentialBackoff = {
        option = "retry-exponential-backoff",
        description = "Exponential backoff for retries (choose 1 for no backoff)",
        default = 2
    },
    retryTimeoutBase = {
        option = "retry-timeout-base",
        description = "Base timeout for retries (in seconds) (choose 0 for no timeout)",
        default = 0.5
    },

    -- Scan keys options
    dataStoreName = {
        option = "data-store-name",
        shortOption = "-d",
        description = "Name of the DataStore",
        prompt = "Enter a value for 'dataStoreName': "
    },
    dataStoreScope = {
        option = "data-store-scope",
        shortOption = "-s",
        description = "Scope of the DataStore",
        prompt = "Enter a value for 'dataStoreScope' (default: 'global'): "
    },
    keyPrefix = {
        option = "key-prefix",
        shortOption = "-P",
        description = "Prefix of the keys to scan",
        prompt = "Enter a value for 'keyPrefix' (default: ''): "
    },

    -- Scan DataStores options
    dataStorePrefix = {
        option = "data-store-prefix",
        shortOption = "-P",
        description = "Prefix of the DataStores to scan",
        prompt = "Enter a value for 'dataStorePrefix' (default: ''): "
    }
}

--[[
    List of configuration flags.
    Defines all command line flags for the application.
]]
local ConfigurationFlags: { [string]: Types.ConfigFlag } = {
    -- Scan keys flags
    excludeDeletedKeys = {
        flag = "exclude-deleted-keys",
        flagInverse = "include-deleted-keys",
        description = "Exclude deleted keys from scan",
        descriptionInverse = "Include deleted keys in scan",
        prompt = "Enter a value for 'excludeDeletedKeys' (0: false, 1: true): "
    },
    allScopes = {
        flag = "all-scopes",
        description = "Scan all scopes",
        override = "dataStoreScope"
    }
}

--[[
    List of commands and their associated configs.
]]
local CommandDetails: { [string]: { [string]: any } } = {
    [Commands.ProcessKeys] = {
        description = "Start a batch process that processes over key names inside of a single data store.",
        positionalArgs = {
            { name = "processName", description = "The name of the process to run" }
        },
        configurations = {
            "universeId",
            "placeId",
            "callback",
            "outputDirectory",
            "dataStoreName",
            "allScopes",
            "dataStoreScope",
            "keyPrefix",
            "excludeDeletedKeys",
            "numProcessingInstances",
            "processItemRateLimit",
            "numRetries",
            "retryTimeoutBase",
            "retryExponentialBackoff",
            "maxTotalFailedItems",
            "maxItemsPerJob",
            "jobQueueMaxSize",
            "errorLogMaxLength",
            "progressRefreshTimeout",
            "memoryStoresExpiration",
            "memoryStoresStorageLimit"
        }
    },
    [Commands.ProcessDataStores] = {
        description = "Start a batch process that processes over data store names.",
        positionalArgs = {
            { name = "processName", description = "The name of the process to run" }
        },
        configurations = {
            "universeId",
            "placeId",
            "callback",
            "outputDirectory",
            "dataStorePrefix",
            "numProcessingInstances",
            "processItemRateLimit",
            "numRetries",
            "retryTimeoutBase",
            "retryExponentialBackoff",
            "maxTotalFailedItems",
            "maxItemsPerJob",
            "jobQueueMaxSize",
            "errorLogMaxLength",
            "progressRefreshTimeout",
            "memoryStoresExpiration",
            "memoryStoresStorageLimit"
        }
    },
    [Commands.Resume] = {
        description = "Resume a previously running batch process.",
        positionalArgs = {
            { name = "processName", description = "The name of the process to resume" }
        },
        configurations = {
            "universeId",
            "outputDirectory",
            "numProcessingInstances",
            "processItemRateLimit",
            "numRetries",
            "retryTimeoutBase",
            "retryExponentialBackoff",
            "maxTotalFailedItems",
            "jobQueueMaxSize",
            "errorLogMaxLength",
            "progressRefreshTimeout",
            "memoryStoresExpiration",
            "memoryStoresStorageLimit"
        }
    },
    [Commands.Cleanup] = {
        description = "Cleanup an old batch process.",
        positionalArgs = {
            { name = "processName", description = "The name of the process to cleanup" }
        },
        configurations = {
            "universeId"
        }
    },
    [Commands.List] = {
        description = "List all batch processes.",
        configurations = {
            "universeId"
        }
    }
}

return {
    ActiveStage1TasksFile = ActiveStage1TasksFile,
    ActiveStage2TasksFile = ActiveStage2TasksFile,
    BatchProcessFile = BatchProcessFile,
    BatchProcessFailedItemLogsMapPrefix = BatchProcessFailedItemLogsMapPrefix,
    BatchProcessFailedItemsOrderedDataStorePrefix = BatchProcessFailedItemsOrderedDataStorePrefix,
    BatchProcessGuidToSessionPathsMapName = BatchProcessGuidToSessionPathsMapName,
    BatchProcessMapName = BatchProcessMapName,
    BatchProcessTaskStatusMapName = BatchProcessTaskStatusMapName,
    CLILogFile = CLILogFile,
    CommandDetails = CommandDetails,
    Commands = Commands,
    CompletedStage1TasksFile = CompletedStage1TasksFile,
    CompletedStage2TasksFile = CompletedStage2TasksFile,
    ConfigurationFlags = ConfigurationFlags,
    ConfigurationOptions = ConfigurationOptions,
    FailedItemsFile = FailedItemsFile,
    GuidToSessionPathsMapExpiration = GuidToSessionPathsMapExpiration,
    PlaceHolder = PlaceHolder,
    SessionLogsDirectory = SessionLogsDirectory,
    SessionTaskRetryConfig = SessionTaskRetryConfig,
    ScanTypes = ScanTypes,
    StageTypes = StageTypes,
    TableColumnWidth = TableColumnWidth
}

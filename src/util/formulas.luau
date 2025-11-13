--!strict

--[[
    This file contains formulas for calculating the maximum and minimum memory stores storage and access that a batch process can use.
]]

-- Local Libraries
local Types = require('../shared/types')

-- Constants
local BUFFER_BYTES = 1024 -- Extra 1kb buffer
local BATCH_PROCESS_OVERHEAD_BYTES = 1125 -- Length of the batch process entry
local FAILED_ITEM_LOG_OVERHEAD_BYTES = 209 -- Length of the failed item log without the truncated error log
local TASK_STATUS_OVERHEAD_BYTES = 229 -- Worst case size of the task status entry without the session paths
local SESSION_PATH_BYTES = 161 -- Length of the session path, accounting for quotes
local STORAGE_POOL_OVERHEAD_BYTES = 45 -- Length of the storage bytes entry
local JOB_OVERHEAD_BYTES = 97 -- Length of the job entry
local WORST_CASE_ITEM_LENGTH_BYTES = 53 -- Worst case length of an item including quotes and comma
local WORST_CASE_ITEM_PAGE_BASE_BYTES = 225 -- Worst case length of an item page including quotes and comma
local SESSION_TASK_RATE_LIMIT = 40 -- The number of session tasks that can be spun up in a minute
local PAGES_SORTED_MAP_MAX_SIZE = 200 -- The maximum size of the pages sorted map
local BYTES_PER_KILOBYTE = 1024 -- The number of bytes in a kilobyte
local ACCESS_OVERHEAD = 17 -- The overhead of the access logic in RUs
local LISTS_PER_MINUTE = 50 -- The number of lists that can be performed in a minute
local CREATE_JOBS_RU = 8 -- The RU cost of creating jobs
local PROCESS_PAGES_RU = 5 -- The RU cost of processing pages
local LOOP_UPDATE_RU = 6 -- The RU cost of updating the loop
local FAILED_ITEM_LOG_RECONCILIATION_RU = 3 -- The RU cost of reconciling the failed item logs map
local STAGE_2_POLLING_RU = 30 -- The RU cost of polling for stage 2
local COMPLETE_PAGE_RU = 4 -- The RU cost of completing a page and reserving quota for failed items

-- Formulas
local Formulas = {}

--[[
    Calculates the maximum memory storesstorage that a batch process can use.
    @param configs Types.ConfigValues - The configurations to use
    @return number - The maximum storage that a batch process can use
]]
Formulas.CalculateMaxStorage = function(configs: Types.ConfigValues): number
    local maxStorageBytes = BUFFER_BYTES 
        + BATCH_PROCESS_OVERHEAD_BYTES + STORAGE_POOL_OVERHEAD_BYTES + TASK_STATUS_OVERHEAD_BYTES -- overhead contribution 
        + configs.jobQueueMaxSize * (WORST_CASE_ITEM_LENGTH_BYTES * configs.maxItemsPerJob + JOB_OVERHEAD_BYTES) -- job queue variable contribution
        + math.min(2 * configs.jobQueueMaxSize, PAGES_SORTED_MAP_MAX_SIZE) * (WORST_CASE_ITEM_LENGTH_BYTES * configs.maxItemsPerJob + WORST_CASE_ITEM_PAGE_BASE_BYTES)  -- item page variable contribution
        + configs.maxTotalFailedItems * (FAILED_ITEM_LOG_OVERHEAD_BYTES + configs.errorLogMaxLength)  -- failed items variable contribution
        + configs.numProcessingInstances * (SESSION_PATH_BYTES + 1) -- guid to session path variable contribution
        + math.min(configs.numProcessingInstances, SESSION_TASK_RATE_LIMIT) * SESSION_PATH_BYTES -- task status variable contribution
    local maxStorage = math.ceil(maxStorageBytes / BYTES_PER_KILOBYTE)
    return maxStorage
end

--[[
    Calculates the minimum memory stores storage that a batch process can use. The minimum is defined to be the amount of usage assuming
    that the batch process can hold at least 2 jobs and 2 item pages. This is needed to ensure the batch process does not freeze indefinitely.
    @param configs Types.ConfigValues - The configurations to use
    @return number - The minimum storage for a batch process to run
]]
Formulas.CalculateMinStorage = function(configs: Types.ConfigValues): number
    local minStorageBytes = BUFFER_BYTES
        + BATCH_PROCESS_OVERHEAD_BYTES + STORAGE_POOL_OVERHEAD_BYTES + TASK_STATUS_OVERHEAD_BYTES -- overhead contribution
        + 2 * (WORST_CASE_ITEM_LENGTH_BYTES * configs.maxItemsPerJob + JOB_OVERHEAD_BYTES) -- job queue variable contribution for 2 jobs
        + 2 * (WORST_CASE_ITEM_LENGTH_BYTES * configs.maxItemsPerJob + WORST_CASE_ITEM_PAGE_BASE_BYTES) -- item page variable contribution for 2 pages
        + configs.numProcessingInstances * (SESSION_PATH_BYTES + 1) -- guid to session path variable contribution
        + math.min(configs.numProcessingInstances, SESSION_TASK_RATE_LIMIT) * SESSION_PATH_BYTES -- task status variable contribution
    local minStorage = math.ceil(minStorageBytes / BYTES_PER_KILOBYTE)
    return minStorage
end

--[[
    Calculates the maximum access that a batch process can use.
    @param configs Types.ConfigValues - The configurations to use
    @return number - The maximum access that a batch process can use
]]
Formulas.CalculateMaxAccess = function(configs: Types.ConfigValues): number
    local loopsPerMinute = 60 / configs.progressRefreshTimeout
    local maxPageMapSize = math.min(2 * configs.jobQueueMaxSize, PAGES_SORTED_MAP_MAX_SIZE)
    local maxAccess = ACCESS_OVERHEAD
        + maxPageMapSize -- Reconciliation
        + CREATE_JOBS_RU * LISTS_PER_MINUTE -- Creating pages and jobs
        + maxPageMapSize * loopsPerMinute -- Listing pages
        + PROCESS_PAGES_RU * maxPageMapSize -- Processing pages
        + LOOP_UPDATE_RU * loopsPerMinute -- Loop update logic
        + FAILED_ITEM_LOG_RECONCILIATION_RU * loopsPerMinute -- Failed item log reconciliation logic
        + math.max(STAGE_2_POLLING_RU * configs.numProcessingInstances, LISTS_PER_MINUTE) -- Stage 2 polling
        + COMPLETE_PAGE_RU * LISTS_PER_MINUTE -- Completing pages
        + math.min(LISTS_PER_MINUTE * configs.maxItemsPerJob, configs.maxTotalFailedItems) -- Reserving quota and writing failed item logs
        + configs.maxTotalFailedItems -- Reading failed item logs on CLI
    return maxAccess
end

return Formulas
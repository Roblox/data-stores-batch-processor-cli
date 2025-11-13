--!strict

--[[
    Command for processing keys in batch.
]]

-- Native Libraries
local process = require('@lune/process')

-- Local Libraries
local Cleanup = require('./cleanup')
local CLIO = require('../util/clio')
local ConfigValidators = require('../config/validators')
local Constants = require('../shared/constants')
local FileIO = require('../util/fileio')
local Monitor = require('./monitor')
local OpenCloudClient = require('../util/open-cloud-client')
local ProcessUtil = require('../util/process-util')
local Stage1Util = require('../util/stage1-util')
local Types = require('../shared/types')

-- ProcessKeys
local ProcessKeys = {}

--[[
    Processes keys according to the provided configurations.
    @param configs Types.ProcessKeysConfigs - The configurations for key processing
]]
ProcessKeys.Execute = function(processName: string, configs: Types.ProcessKeysConfigs): ()
    local openCloudClient = OpenCloudClient.CreateOpenCloudClient(process.env['API_KEY'], configs.universeId)

    -- Validate the API Key
    local validateAPIKeySuccess: boolean, validateAPIKeyErrorMessage: string? = ConfigValidators.ValidateAPIKey(openCloudClient, process.env['API_KEY'])
    if not validateAPIKeySuccess then
        CLIO.Error(validateAPIKeyErrorMessage :: string)
        return
    end

    -- Validate the callback
    local validateCallbackSuccess: boolean, validateCallbackErrorMessage: string? = ConfigValidators.ValidateCallbackWithSessionTask(openCloudClient, configs.callback, configs.universeId, configs.placeId)
    if not validateCallbackSuccess then
        CLIO.Error(validateCallbackErrorMessage :: string)
    end

    -- Validate the maxItemsPerJob value is compatible with excluded deleted keys
    local validateMaxItemsPerJobWithExcludedDeletedKeysSuccess: boolean, validateMaxItemsPerJobWithExcludedDeletedKeysErrorMessage: string? = ConfigValidators.ValidateMaxItemsPerJobWithExcludedDeletedKeys(configs)
    if not validateMaxItemsPerJobWithExcludedDeletedKeysSuccess then
        CLIO.Error(validateMaxItemsPerJobWithExcludedDeletedKeysErrorMessage :: string)
        return
    end

    -- Validate the memoryStoresStorageLimit
    local validateMemoryStoresStorageLimitSuccess: boolean, validateMemoryStoresStorageLimitErrorMessage: string? = ConfigValidators.ValidateMemoryStoresStorageLimitBounds(configs)
    if not validateMemoryStoresStorageLimitSuccess then
        CLIO.Error(validateMemoryStoresStorageLimitErrorMessage :: string)
        return
    end

    -- Check if the process exists in data stores or memory stores
    local existingBatchProcessDataStores: Types.OpenCloudResponse = openCloudClient.getDataStoreEntry(Constants.BatchProcessMapName, "global", processName)
    if existingBatchProcessDataStores.status ~= 200 and existingBatchProcessDataStores.status ~= 404 then
        CLIO.Error("There was an error checking if the process exists. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(existingBatchProcessDataStores))
    end
    local existingBatchProcessMemoryStores: Types.OpenCloudResponse = openCloudClient.getSortedMapEntry(Constants.BatchProcessMapName, processName)
    if existingBatchProcessMemoryStores.status ~= 200 and existingBatchProcessMemoryStores.status ~= 404 then
        CLIO.Error("There was an error checking if the process exists. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(existingBatchProcessMemoryStores))
    end

    -- Cover all cases where the process exists in either data stores or memory stores
    -- If it exists in both data stores and memory stores, flag for cleanup
    -- If it exists in memory stores but not data stores, backup the process from memory stores to data stores and flag for cleanup
    -- If it exists in data stores but not memory stores, flag for cleanup
    -- If it doesn't exist in either data stores or memory stores, do nothing
    local batchProcessExists = false
    if existingBatchProcessDataStores.status == 200 and existingBatchProcessMemoryStores.status == 200 then -- Exists in both data stores and memory stores
        batchProcessExists = true

    elseif existingBatchProcessDataStores.status == 404 and existingBatchProcessMemoryStores.status == 200 then -- Exists in memory stores but not data stores
        local backupProcessToDataStores = openCloudClient.createDataStoreEntry(Constants.BatchProcessMapName, "global", processName, existingBatchProcessMemoryStores.body.value)
        if backupProcessToDataStores.status ~= 200 then
            CLIO.Error("There was an error backing up the process to data stores. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(backupProcessToDataStores))
        end
        batchProcessExists = true

    elseif existingBatchProcessDataStores.status == 200 and existingBatchProcessMemoryStores.status == 404 then -- Exists in data stores but not memory stores
        batchProcessExists = true
    end

    -- If the batch process exists, we can try to clean it up.
    if batchProcessExists then
        CLIO.Print("Process already exists. Would you like to cleanup this batch process?")
        CLIO.PromptForConfirmation("cleanup the process")
        Cleanup.Execute(processName, {
            universeId = configs.universeId
        })
    end

    -- Prompt to start batch process
    CLIO.PrintConfigs(Constants.CommandDetails[Constants.Commands.ProcessKeys].configurations, configs)
    CLIO.PrintMemoryStoresUsageInformation(configs)
    CLIO.ShowProcessWidth()
    CLIO.PromptForConfirmation("start the process")
    CLIO.PrintDirectionToCLILogFile(processName, configs.outputDirectory)

    -- Clear and recreate the output files
    FileIO.RemoveOutputFiles(processName, configs.outputDirectory)
    FileIO.CreateOutputFiles(processName, configs.outputDirectory)

    -- Start the stage 1 task
    local startProcessTaskStatus: Types.ProcessTaskStatus = {
        numInstances = configs.numProcessingInstances :: number,
        stage1SessionPaths = {},
        stage2SessionPaths = {},
    }
    Stage1Util.InitializeProcessTaskStatus(processName, startProcessTaskStatus, configs, openCloudClient)
    Stage1Util.CreateSessionTask(Constants.ScanTypes.Keys, processName, startProcessTaskStatus, configs, openCloudClient)

    -- Monitor the process
    Monitor.Execute(processName, Constants.ScanTypes.Keys, configs)
    ProcessUtil.FinalizeOnExit(processName, configs, openCloudClient)
end

return ProcessKeys
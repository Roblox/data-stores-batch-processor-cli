--!strict

--[[
    Command for resuming a previously interrupted batch processing operation.
]]

-- Native Libraries
local process = require('@lune/process')

-- Local Libraries
local CLIO = require('../util/clio')
local ConfigValidators = require('../config/validators')
local Constants = require('../shared/constants')
local FileIO = require('../util/fileio')
local Monitor = require('./monitor')
local OpenCloudClient = require('../util/open-cloud-client')
local ProcessUtil = require('../util/process-util')
local Types = require('../shared/types')

-- Resume
local Resume = {}

--[[
    Combines the old configs with the new configs
    @param configs Types.ResumeConfigs - The new configs
    @param pastConfigs Types.AnyConfigs - The old configs
    @return Types.AnyConfigs - The combined configs
]]
local function combineConfigs(configs: Types.ResumeConfigs, pastConfigs: Types.AnyConfigs): Types.AnyConfigs
    local combinedConfigs = {}
    for configName, configValue in pairs(pastConfigs) do
        if configs[configName] ~= Constants.PlaceHolder and configs[configName] ~= nil then
            combinedConfigs[configName] = configs[configName]
        else
            combinedConfigs[configName] = configValue
        end
    end
    return combinedConfigs :: Types.AnyConfigs
end

--[[
    Updates the process task status with the new number of instances
    @param processName string - The name of the process
    @param configs Types.AnyConfigs - The new configs
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
]]
local function updateProcessTaskStatus(processName: string, configs: Types.AnyConfigs, openCloudClient: OpenCloudClient.OpenCloudClient): ()
    local existingProcessTaskStatus = openCloudClient.getSortedMapEntry(Constants.BatchProcessTaskStatusMapName, processName)
    if existingProcessTaskStatus.status ~= 200 then
        CLIO.Error("Failed to get process task status. Reason: " .. OpenCloudClient.GetBodyAsString(existingProcessTaskStatus))
    end

    local processTaskStatus = existingProcessTaskStatus.body.value
    processTaskStatus.numInstances = configs.numProcessingInstances
    
    local updateProcessTaskStatusRes = openCloudClient.updateSortedMapEntry(
        Constants.BatchProcessTaskStatusMapName, 
        processName,
        processTaskStatus,
        nil,
        configs.memoryStoresExpiration
    )
    if updateProcessTaskStatusRes.status ~= 200 then
        CLIO.Error("Failed to update process task status. Reason: " .. OpenCloudClient.GetBodyAsString(updateProcessTaskStatusRes))
    end
end

--[[
    Resumes a previously interrupted batch processing operation.
    @param configs Types.ResumeConfigs - The configurations for resuming processing
]]
Resume.Execute = function(processName: string, configs: Types.ResumeConfigs): ()
     local openCloudClient = OpenCloudClient.CreateOpenCloudClient(process.env['API_KEY'], configs.universeId)

    -- Validate the API Key
    local validateAPIKeySuccess: boolean, errorMessage: string? = ConfigValidators.ValidateAPIKey(openCloudClient, process.env['API_KEY'])
    if not validateAPIKeySuccess then
        CLIO.Error(errorMessage :: string)
        return
    end

    -- Check if theprocess exists in data stores or memory stores
    local existingBatchProcessDataStores: Types.OpenCloudResponse = openCloudClient.getDataStoreEntry(Constants.BatchProcessMapName, "global", processName)
    if existingBatchProcessDataStores.status ~= 200 and existingBatchProcessDataStores.status ~= 404 then
        CLIO.Error("There was an error checking if the process exists. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(existingBatchProcessDataStores))
    end
    local existingBatchProcessMemoryStores: Types.OpenCloudResponse = openCloudClient.getSortedMapEntry(Constants.BatchProcessMapName, processName)
    if existingBatchProcessMemoryStores.status ~= 200 and existingBatchProcessMemoryStores.status ~= 404 then
        CLIO.Error("There was an error checking if the process exists. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(existingBatchProcessMemoryStores))
    end

    -- Cover all cases where the process exists in either data stores or memory stores
    -- If it exists in both data stores and memory stores, load the process info from memory stores
    -- If it exists in memory stores but not data stores, backup the process from memory stores to data stores and load the process info from memory stores
    -- If it exists in data stores but not memory stores, error out since the process has expired
    -- If it doesn't exist in either data stores or memory stores, error out since the process doesn't exist
    local processInfo: Types.BatchProcess
    if existingBatchProcessDataStores.status == 200 and existingBatchProcessMemoryStores.status == 200 then -- Exists in both data stores and memory stores
        processInfo = existingBatchProcessMemoryStores.body.value

    elseif existingBatchProcessDataStores.status == 404 and existingBatchProcessMemoryStores.status == 200 then -- Exists in memory stores but not data stores
        -- Backup the process from memory stores to data stores
        local backupProcessToDataStores = openCloudClient.createDataStoreEntry(Constants.BatchProcessMapName, "global", processName, existingBatchProcessMemoryStores.body.value)
        if backupProcessToDataStores.status ~= 200 then
            CLIO.Error("There was an error backing up the process to data stores. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(backupProcessToDataStores))
        end
        processInfo = existingBatchProcessMemoryStores.body.value

    elseif existingBatchProcessDataStores.status == 200 and existingBatchProcessMemoryStores.status == 404 then -- Exists in data stores but not memory stores
        CLIO.Error("Process " .. processName .. " has expired. Please use the process-keys or process-data-stores command to create a new process.")

    elseif existingBatchProcessDataStores.status == 404 and existingBatchProcessMemoryStores.status == 404 then -- Doesn't exist in either data stores or memory stores
        CLIO.Error("Process " .. processName .. " does not exist.")
    end

    -- Ensure the process is not done
    if processInfo.status == "Done" then
        CLIO.Error("Process " .. processName .. " cannot be resumed, since it has already completed. Please use the process-keys or process-data-stores command to create a new process.")
    end

    -- Combine the old configs with the new configs
    local combinedConfigs = combineConfigs(configs, processInfo.configs)

    -- Validate the memoryStoresStorageLimit
    local validateMemoryStoresStorageLimitSuccess: boolean, validateMemoryStoresStorageLimitErrorMessage: string? = ConfigValidators.ValidateMemoryStoresStorageLimitBounds(combinedConfigs)
    if not validateMemoryStoresStorageLimitSuccess then
        CLIO.Error(validateMemoryStoresStorageLimitErrorMessage :: string)
        return
    end

    -- Validate that the failed items is large enough to resume
    local validateEnoughFailedItems: boolean, validateEnoughFailedItemsErrorMessage: string? = ConfigValidators.ValidateEnoughFailedItems(combinedConfigs.maxTotalFailedItems, processInfo.failedItems)
    if not validateEnoughFailedItems then
        CLIO.Error(validateEnoughFailedItemsErrorMessage :: string)
    end

    -- Print the configs depending on the scan type
    local scanType: Types.ScanType = processInfo.scanType
    if scanType == Constants.ScanTypes.Keys then
        CLIO.PrintConfigs(Constants.CommandDetails[Constants.Commands.ProcessKeys].configurations, combinedConfigs)
    elseif scanType == Constants.ScanTypes.DataStores then
        CLIO.PrintConfigs(Constants.CommandDetails[Constants.Commands.ProcessDataStores].configurations, combinedConfigs)
    end

    -- Prompt to resume the process
    CLIO.PrintMemoryStoresUsageInformation(combinedConfigs)
    CLIO.ShowProcessWidth()
    CLIO.PromptForConfirmation("resume the process")
    CLIO.PrintDirectionToCLILogFile(processName, combinedConfigs.outputDirectory)

    -- Clear and recreate the output files
    FileIO.RemoveOutputFiles(processName, combinedConfigs.outputDirectory)
    FileIO.CreateOutputFiles(processName, combinedConfigs.outputDirectory)

    -- Monitor the process
    ProcessUtil.ExpireStage1SessionTasks(processName, combinedConfigs, openCloudClient)
    ProcessUtil.ExpireStage2SessionTasks(processName, combinedConfigs, openCloudClient)
    updateProcessTaskStatus(processName, combinedConfigs, openCloudClient)
    Monitor.Execute(processName, scanType, combinedConfigs, processInfo)
    ProcessUtil.FinalizeOnExit(processName, combinedConfigs, openCloudClient)
end

return Resume

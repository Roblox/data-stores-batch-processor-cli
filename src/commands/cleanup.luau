--!strict

--[[
    Command for resuming a previously interrupted batch processing operation.
]]

-- Native Libraries
local process = require('@lune/process')
local task = require('@lune/task')

-- External Libraries
local llc_tasks = require('../../libs/llc_tasks/tasks')

-- Local Libraries
local CLIO = require('../util/clio')
local ConfigValidators = require('../config/validators')
local Constants = require('../shared/constants')
local FileIO = require('../util/fileio')
local OpenCloudClient = require('../util/open-cloud-client')
local ProcessUtil = require('../util/process-util')
local RetryUtil = require('../util/retry-util')
local Types = require('../shared/types')

--[[
    Starts a cleanup task for a batch process.
    @param processName string - The name of the process
    @param configs Types.AnyConfigs - The configurations for the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
    @return string - The session path of the cleanup task
]]
local function startCleanupTask(processName: string, configs: Types.AnyConfigs, openCloudClient: OpenCloudClient.OpenCloudClient): string
    local cleanupScript = FileIO.ReadFile('src/scripts/cleanup.luau')
    if not cleanupScript then
        CLIO.Error("Failed to read cleanup script. Please try again.")
    end

    -- Create a new task with the script and basic configuration
    local cleanupTask = llc_tasks.create(
        cleanupScript :: string, 
        {
            api_key = process.env['API_KEY'],
            universe_id = configs.universeId,
            place_id = configs.placeId,
        }
    )

    -- Start the task with the provided configurations
    local startCleanupTaskSuccess, cleanupRes, cleanupError = RetryUtil.RetryAsync(function()
            return cleanupTask:start(processName, configs)
        end, 
        Constants.SessionTaskRetryConfig.MaxAttempts, 
        Constants.SessionTaskRetryConfig.TimeoutBase, 
        Constants.SessionTaskRetryConfig.TimeoutExponentialBackoff
    )
    if not startCleanupTaskSuccess or cleanupError then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Warning: Failed to start stage 1 task.")
        CLIO.Error("Failed to start cleanup task. Please try again later.")
    end

    return cleanupRes.task_create_res.path
end

--[[
    Cleans up the memory stores for a batch processing operation by running the cleanup script.
    @param processName string - The name of the process
    @param configs Types.AnyConfigs - The configurations for the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
]]
local function cleanupBatchProcess(processName: string, configs: Types.AnyConfigs, openCloudClient: OpenCloudClient.OpenCloudClient): ()
    local cleanupSessionPath = startCleanupTask(processName, configs, openCloudClient)
    CLIO.Print("Cleanup task started with session task path")
    CLIO.Print("\t" .. cleanupSessionPath)
    CLIO.Print("\tWaiting for task to complete (this may take up to 5 minutes)...")
   
    -- Wait for the cleanup task to complete
    local timeouts = 0
    repeat 
        task.wait(1)
        local getSessionStatus = openCloudClient.getLuauExecutionSessionStatus(cleanupSessionPath)

        -- If the cleanup task failed, check if it timed out and restart it if it did
        if getSessionStatus.body and getSessionStatus.body.state == "FAILED" then
            if getSessionStatus.body.error.code == "DEADLINE_EXCEEDED" then
                -- If the cleanup task timed out 3 times, error out
                timeouts += 1
                if timeouts >= 3 then
                    CLIO.Error("Cleanup task timed out 3 times. Please try again.")
                end

                -- Start a new cleanup task
                cleanupSessionPath = startCleanupTask(processName, configs, openCloudClient)
                CLIO.Print("Cleanup task timed out. New cleanup task started with session task path\n\t" .. cleanupSessionPath .. "\n\tWaiting for task to complete (this may take up to 5 minutes)...")
            else
                CLIO.Error("Cleanup task failed. Please try again.")
            end
        end
    until getSessionStatus.status == 200 and getSessionStatus.body.state == "COMPLETE"
end

-- Cleanup
local Cleanup = {}

--[[
    Cleans up an old batch processing operation.
    @param processName string - The name of the process
    @param configs Types.CleanupConfigs - The configurations for cleaning up
]]
Cleanup.Execute = function(processName: string, configs: Types.CleanupConfigs): ()
     local openCloudClient = OpenCloudClient.CreateOpenCloudClient(process.env['API_KEY'], configs.universeId)

    -- Validate the API Key
    local validateAPIKeySuccess: boolean, validateAPIKeyErrorMessage: string? = ConfigValidators.ValidateAPIKey(openCloudClient, process.env['API_KEY'])
    if not validateAPIKeySuccess then
        CLIO.Error(validateAPIKeyErrorMessage :: string)
        return
    end

    -- Ensure the process exists in data stores or memory stores
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
    -- If it exists in data stores but not memory stores, load the process info from data stores
    -- If it doesn't exist in either data stores or memory stores, error out since the process doesn't exist
    local processInfo: Types.BatchProcess
    if existingBatchProcessDataStores.status == 200 and existingBatchProcessMemoryStores.status == 200 then -- Exists in both data stores and memory stores
        processInfo = existingBatchProcessMemoryStores.body.value

    elseif existingBatchProcessDataStores.status == 404 and existingBatchProcessMemoryStores.status == 200 then -- Exists in memory stores but not data stores
        local backupProcessToDataStores = openCloudClient.createDataStoreEntry(Constants.BatchProcessMapName, "global", processName, existingBatchProcessMemoryStores.body.value)
        if backupProcessToDataStores.status ~= 200 then
            CLIO.Error("There was an error backing up the process to data stores. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(backupProcessToDataStores))
        end
        processInfo = existingBatchProcessMemoryStores.body.value

    elseif existingBatchProcessDataStores.status == 200 and existingBatchProcessMemoryStores.status == 404 then -- Exists in data stores but not memory stores
        processInfo = existingBatchProcessDataStores.body.value

    elseif existingBatchProcessDataStores.status == 404 and existingBatchProcessMemoryStores.status == 404 then -- Doesn't exist in either data stores or memory stores
        CLIO.Error("Process " .. processName .. " does not exist.")
    end

    -- Wait until all sessions are completed
    ProcessUtil.StopSessionTasks(processName, openCloudClient, processInfo.configs)
    ProcessUtil.WaitForSessionsToComplete(processName, openCloudClient)

    -- Run the cleanup task
    cleanupBatchProcess(processName, processInfo.configs, openCloudClient)

    -- Cleanup complete
    CLIO.Print("Cleanup complete!")
end

return Cleanup
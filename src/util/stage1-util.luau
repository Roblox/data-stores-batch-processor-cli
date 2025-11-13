--!strict

--[[
    This module handles the creation and management of stage 1 tasks for batch processing.
]]

-- Native Libraries
local process = require('@lune/process')

-- External Libraries
local llc_tasks = require('../../libs/llc_tasks/tasks')

-- Local Libraries
local CLIO = require('./clio')
local Constants = require('../shared/constants')
local FileIO = require('./fileio')
local GuidUtil = require('./guid-util')
local OpenCloudClient = require('./open-cloud-client')
local ProcessUtil = require('./process-util')
local RetryUtil = require('./retry-util')
local Types = require('../shared/types')

--[[
    Stage1Util
]]
local Stage1Util = {}

--[[
    Gets the stage 1 script content.
    @param scanType Types.ScanType - The type of scan to perform
    @return string - The contents of the stage 1 script file
]]
local function getStage1Script(scanType: Types.ScanType): string
    -- Read the correct stage 1 script
    local script: string?
    if scanType == Constants.ScanTypes.Keys then
        script = FileIO.ReadFile('src/scripts/stage1-scan-keys.luau')
    elseif scanType == Constants.ScanTypes.DataStores then
        script = FileIO.ReadFile('src/scripts/stage1-scan-data-stores.luau')
    end
    if not script then
        CLIO.Error('Failed to read stage 1 script. Please try again.')
    end

    return script :: string
end

--[[
    Initializes the process task status.
    @param processName string - The name of the batch process
    @param processTaskStatus Types.ProcessTaskStatus - The process task status
    @param configs Types.AnyConfigs - The configuration settings for the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The client for interacting with Open Cloud
]]
Stage1Util.InitializeProcessTaskStatus = function(
    processName: string,
    processTaskStatus: Types.ProcessTaskStatus,
    configs: Types.AnyConfigs,
    openCloudClient: OpenCloudClient.OpenCloudClient
): ()
    local createProcessTaskStatusRes = openCloudClient.createSortedMapEntry(
        Constants.BatchProcessTaskStatusMapName, 
        processName,
        processTaskStatus,
        nil,
        configs.memoryStoresExpiration
    )
    if createProcessTaskStatusRes.status == 409 then
        -- If the process task status already exists, update it instead
        local updateProcessTaskStatusRes = openCloudClient.updateSortedMapEntry(
            Constants.BatchProcessTaskStatusMapName, 
            processName,
            processTaskStatus,
            nil,
            configs.memoryStoresExpiration
        )
        if updateProcessTaskStatusRes.status ~= 200 then
            CLIO.Error("Failed to initialize process task status. Reason: " .. OpenCloudClient.GetBodyAsString(updateProcessTaskStatusRes))
        end
    elseif createProcessTaskStatusRes.status ~= 200 then
        CLIO.Error("Failed to initialize process task status. Reason: " .. OpenCloudClient.GetBodyAsString(createProcessTaskStatusRes))
    end
end

--[[
    Creates a Session Task for stage 1 processing.
    @param scanType Types.ScanType - The type of scan to perform
    @param processName string - The name of the batch process
    @param previousProcessTaskStatus Types.ProcessTaskStatus - The previous process task status
    @param configs Types.AnyConfigs - The configuration settings for the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The client for interacting with Open Cloud
]]
Stage1Util.CreateSessionTask = function(
    scanType: Types.ScanType, 
    processName: string, 
    previousProcessTaskStatus: Types.ProcessTaskStatus,
    configs: Types.AnyConfigs, 
    openCloudClient: OpenCloudClient.OpenCloudClient
): ()
    -- Load the stage 1 script that contains the scanning logic
    local stage1Script = getStage1Script(scanType)

    -- Create a new task with the script and basic configuration
    local stage1Task = llc_tasks.create(
        stage1Script, 
        {
            api_key = process.env['API_KEY'],
            universe_id = configs.universeId,
            place_id = configs.placeId,
        }
    )

    -- Generate a unique identifier for this task
    local guid = GuidUtil.GenerateGuid()

    -- Start the task with the provided configurations
    local success, stage1Res, stage1Error = RetryUtil.RetryAsync(function()
            return stage1Task:start(guid, processName, configs)
        end, 
        Constants.SessionTaskRetryConfig.MaxAttempts, 
        Constants.SessionTaskRetryConfig.TimeoutBase, 
        Constants.SessionTaskRetryConfig.TimeoutExponentialBackoff
    )
    if not success or stage1Error then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Warning: Failed to start stage 1 task.")
        return
    end

    -- Update the Session Task status map
    local updateProcessTaskStatusRes = openCloudClient.updateSortedMapEntry(
        Constants.BatchProcessTaskStatusMapName,
        processName,
        {
            numInstances = previousProcessTaskStatus.numInstances,
            stage1SessionPaths = { stage1Res.task_create_res.path },
            stage2SessionPaths = previousProcessTaskStatus.stage2SessionPaths,
        },
        nil,
        configs.memoryStoresExpiration
    )
    if updateProcessTaskStatusRes.status == 500 or updateProcessTaskStatusRes.status == 429 then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, 
            "Error: There was a critical Open Cloud error. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(updateProcessTaskStatusRes)
        )
        CLIO.Error("There was a critical Open Cloud error. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(updateProcessTaskStatusRes), function()
            ProcessUtil.FinalizeOnExit(processName, configs, openCloudClient)
        end)
    end
    if updateProcessTaskStatusRes.status ~= 200 then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, 
            "Warning: Failed to update process task status map for " .. processName .. ". Reason: " .. OpenCloudClient.GetBodyAsString(updateProcessTaskStatusRes)
        )
        return
    end

    -- Create a sorted map entry to track this task in Open Cloud
    local createSortedMapEntryRes = openCloudClient.createSortedMapEntry(
        Constants.BatchProcessGuidToSessionPathsMapName,
        guid,
        stage1Res.task_create_res.path,
        nil,
        Constants.GuidToSessionPathsMapExpiration
    )
    if createSortedMapEntryRes.status == 500 or createSortedMapEntryRes.status == 429 then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, 
            "Error: There was a critical Open Cloud error. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(createSortedMapEntryRes)
        )
        CLIO.Error("There was a critical Open Cloud error. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(createSortedMapEntryRes), function()
            ProcessUtil.FinalizeOnExit(processName, configs, openCloudClient)
        end)
    end
    if createSortedMapEntryRes.status ~= 200 then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, 
            "Warning: Failed to create sorted map entry mapping the guid to the stage 1 session path for " .. stage1Res.task_create_res.path .. 
            ". Reason: " .. OpenCloudClient.GetBodyAsString(createSortedMapEntryRes)
        )
        return
    end

    -- Record the task in the active tasks file for monitoring
    FileIO.AppendLineToFile(
        configs.outputDirectory .. "/" .. processName .. "/" .. Constants.ActiveStage1TasksFile,
        tostring(stage1Res.task_create_res.path)
    )
end

return Stage1Util
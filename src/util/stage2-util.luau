--!strict

--[[
    This module handles the creation and management of stage 2 tasks for batch processing.
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

-- Global Variables
local stage2Callback: string? = nil

--[[
    Gets the stage 2 script content and injects the callback function.
    @param callback string - The filepath to the Luau script that will be executed for each item
    @return string - The complete stage 2 script with injected callback
]]
local function getStage2Script(callback: string): string
    -- Read the callback file that contains the user's processing logic
    if stage2Callback == nil then
        local file = FileIO.ReadFile(callback)
        if not file then
            CLIO.Error('Failed to read callback file. Please try again.')
        end
        stage2Callback = file
    end

    -- Create the callback function wrapper
    local callbackWrapper = "local processItemBuilder = function()\n" .. stage2Callback :: string .. "\nend\n"

    -- Read the stage 2 template file that contains the processing framework
    local script = FileIO.ReadFile('src/scripts/stage2.luau')
    if not script then
        CLIO.Error('Failed to read stage 2 script. Please try again.')
    end

    -- Combine the callback wrapper with the stage 2 template
    local combinedScript = callbackWrapper .. "\n" .. script :: string
    return combinedScript
end

--[[
    Stage2Util
]]
local Stage2Util = {}

--[[
    Creates a Session Task for stage 2 processing.
    @param processName string - The name of the batch process
    @param previousProcessTaskStatus Types.ProcessTaskStatus - The previous process task status
    @param configs Types.AnyConfigs - The configuration settings for the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The client for interacting with Open Cloud
]]
Stage2Util.CreateSessionTask = function(
    processName: string, 
    previousProcessTaskStatus: Types.ProcessTaskStatus,
    configs: Types.AnyConfigs, 
    openCloudClient: OpenCloudClient.OpenCloudClient
): ()
    -- Load and prepare the stage 2 script with the user's callback
    local stage2Script = getStage2Script(configs.callback)

    -- Create a new task with the script and basic configuration
    local stage2Task = llc_tasks.create(
        stage2Script, 
        {
            api_key = process.env['API_KEY'],
            universe_id = configs.universeId,
            place_id = configs.placeId,
        }
    )

    -- Generate a unique identifier for this task
    local guid = GuidUtil.GenerateGuid()

    -- Start the task with the provided configurations
    local success, stage2Res, stage2Error = RetryUtil.RetryAsync(function()
            return stage2Task:start(guid, processName, configs)
        end, 
        Constants.SessionTaskRetryConfig.MaxAttempts, 
        Constants.SessionTaskRetryConfig.TimeoutBase, 
        Constants.SessionTaskRetryConfig.TimeoutExponentialBackoff
    )
    if not success or stage2Error then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Warning: Failed to start stage 2 task.")
        return
    end

    -- Update the Session Task status map
    local newStage2SessionPaths = previousProcessTaskStatus.stage2SessionPaths
    table.insert(newStage2SessionPaths, stage2Res.task_create_res.path)
    local updateProcessTaskStatusRes = openCloudClient.updateSortedMapEntry(
        Constants.BatchProcessTaskStatusMapName,
        processName,
        {
            numInstances = previousProcessTaskStatus.numInstances,
            stage1SessionPaths = previousProcessTaskStatus.stage1SessionPaths,
            stage2SessionPaths = newStage2SessionPaths,
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
        stage2Res.task_create_res.path,
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
            "Warning: Failed to create sorted map entry mapping the guid to the stage 2 session path for " .. stage2Res.task_create_res.path .. 
            ". Reason: " .. OpenCloudClient.GetBodyAsString(createSortedMapEntryRes)
        )
        return
    end

    -- Record the task in the active tasks file for monitoring
    FileIO.AppendLineToFile(
        configs.outputDirectory .. "/" .. processName .. "/" .. Constants.ActiveStage2TasksFile,
        tostring(stage2Res.task_create_res.path)
    )
end

return Stage2Util
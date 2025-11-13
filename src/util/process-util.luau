--!strict

--[[
    Main utility functions for managing batch processes.
]]

-- Native Libraries
local fs = require('@lune/fs')
local serde = require('@lune/serde')
local task = require('@lune/task')

-- Local Libraries
local CLIO = require('../util/clio')
local Constants = require('../shared/constants')
local FileIO = require('../util/fileio')
local OpenCloudClient = require('../util/open-cloud-client')
local TableUtil = require('../util/table-util')
local TimeUtil = require('../util/time-util')
local Types = require('../shared/types')

-- Constants
local READ_TASK_STATUS_INTERVAL = 5

-- Global variables
local nextTimestamp: number? = nil

--[[
    Writes the logs of a completed session to the output file.
    @param processName string - The name of the process
    @param sessionPath string - The path of the session task
    @param stageType Types.StageType - The type of stage that the session task is in
    @param configs Types.AnyConfigs - The configurations for the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
]]
local function writeCompletedSessionLogs(
    processName: string,
    sessionPath: string, 
    sessionStatusBody: any,
    stageType: Types.StageType,    
    configs: Types.AnyConfigs, 
    openCloudClient: OpenCloudClient.OpenCloudClient
): ()
    -- Parse out the session id
    local sessionId = string.match(sessionPath, "([^/]+)$")
    if not sessionId then
        CLIO.Error("Failed to parse session ID from session path... Something went wrong.")
    end

    -- Get the logs
    local logs = openCloudClient.getLuauExecutionSessionLogs(sessionPath)
    if logs.status ~= 200 then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Warning: Failed to get session logs. Reason: " .. OpenCloudClient.GetBodyAsString(logs))
        return
    end

    local logsOutput = table.concat(logs.body.luauExecutionSessionTaskLogs[1].messages, "\n")
    if sessionStatusBody.state == "COMPLETE" then
        logsOutput = logsOutput .. "\nSession Task Completed Successfully"
    elseif sessionStatusBody.state == "FAILED" and sessionStatusBody.error then
        logsOutput = logsOutput .. "\nSession Task Failed with error: " .. sessionStatusBody.error.message
    end

    -- Write the logs to the output file
    FileIO.WriteFile(
        configs.outputDirectory .. "/" .. 
        processName .. "/" ..
        Constants.SessionLogsDirectory .. "/" .. 
        stageType .. "/" .. 
        sessionId :: string .. ".output", 
        logsOutput
    )
end

-- ProcessUtil
local ProcessUtil = {}

--[[
    Expires Stage 1 Session Tasks that may have died.
    @param processName string - The name of the process
    @param configs Types.AnyConfigs - The configurations for the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
]]
ProcessUtil.ExpireStage1SessionTasks = function(
    processName: string, 
    configs: Types.AnyConfigs, 
    openCloudClient: OpenCloudClient.OpenCloudClient
): ()
    local processTaskStatus = openCloudClient.getSortedMapEntry(
        Constants.BatchProcessTaskStatusMapName, 
        processName
    )
    if processTaskStatus.status ~= 200 then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Warning: Failed to get process task status. Reason: " .. OpenCloudClient.GetBodyAsString(processTaskStatus))
        return
    end

    local status: Types.ProcessTaskStatus = processTaskStatus.body.value

    -- Remove completed stage 1 tasks
    local activeStage1 = {}
    for _, stage1SessionPath in ipairs(status.stage1SessionPaths) do
        local getStage1Status = openCloudClient.getLuauExecutionSessionStatus(stage1SessionPath)
        if getStage1Status.status == 404 then
            continue
        elseif getStage1Status.status ~= 200 then
            FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Warning: Failed to get stage 1 status for " .. stage1SessionPath .. ". Reason: " .. OpenCloudClient.GetBodyAsString(getStage1Status))
            return
        end
        if getStage1Status.body.state == "PROCESSING" then
            table.insert(activeStage1, stage1SessionPath)
        else
            FileIO.AppendLineToFile(
                configs.outputDirectory .. "/" .. processName .. "/" .. Constants.CompletedStage1TasksFile, 
                stage1SessionPath
            )
            writeCompletedSessionLogs(processName, stage1SessionPath, getStage1Status.body, Constants.StageTypes.Stage1, configs, openCloudClient)
        end
    end

    -- Update the Session Task status
    local newStatus = {
        numInstances = status.numInstances,
        stage1SessionPaths = activeStage1,
        stage2SessionPaths = status.stage2SessionPaths,
    }
    openCloudClient.updateSortedMapEntry(
        Constants.BatchProcessTaskStatusMapName, 
        processName, 
        newStatus, 
        nil, 
        configs.memoryStoresExpiration
    )
    
    -- Update the active stage 1 and 2 task files
    FileIO.WriteFile(
        configs.outputDirectory .. "/" .. processName .. "/" .. Constants.ActiveStage1TasksFile, 
        table.concat(activeStage1, "\n") .. (#activeStage1 > 0 and "\n" or "")
    )
end

--[[
    Expires Stage 2 Session Tasks that may have died.
    @param processName string - The name of the process
    @param configs Types.AnyConfigs - The configurations for the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
]]
ProcessUtil.ExpireStage2SessionTasks = function(
    processName: string, 
    configs: Types.AnyConfigs, 
    openCloudClient: OpenCloudClient.OpenCloudClient
): ()
    local processTaskStatus = openCloudClient.getSortedMapEntry(
        Constants.BatchProcessTaskStatusMapName, 
        processName
    )
    if processTaskStatus.status ~= 200 then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Warning: Failed to get process task status. Reason: " .. OpenCloudClient.GetBodyAsString(processTaskStatus))
        return
    end

    local status: Types.ProcessTaskStatus = processTaskStatus.body.value

    -- Remove completed stage 2 tasks
    local activeStage2 = {}
    for _, stage2SessionPath in ipairs(status.stage2SessionPaths) do
        local getStage2Status = openCloudClient.getLuauExecutionSessionStatus(stage2SessionPath)
        if getStage2Status.status == 404 then
            continue
        elseif getStage2Status.status ~= 200 then
            FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Warning: Failed to get stage 2 status for " .. stage2SessionPath .. ". Reason: " .. OpenCloudClient.GetBodyAsString(getStage2Status))
            return
        end
        if getStage2Status.body.state == "PROCESSING" then
            table.insert(activeStage2, stage2SessionPath)
        else
            FileIO.AppendLineToFile(
                configs.outputDirectory .. "/" .. processName .. "/" .. Constants.CompletedStage2TasksFile, 
                stage2SessionPath
            )
            writeCompletedSessionLogs(processName, stage2SessionPath, getStage2Status.body, Constants.StageTypes.Stage2, configs, openCloudClient)
        end
    end

    -- Update the Session Task status
    local newStatus = {
        numInstances = status.numInstances,
        stage1SessionPaths = status.stage1SessionPaths,
        stage2SessionPaths = activeStage2,
    }
    openCloudClient.updateSortedMapEntry(
        Constants.BatchProcessTaskStatusMapName, 
        processName, 
        newStatus, 
        nil, 
        configs.memoryStoresExpiration
    )
    
    -- Update the active stage 2 task files
    FileIO.WriteFile(
        configs.outputDirectory .. "/" .. processName .. "/" .. Constants.ActiveStage2TasksFile, 
        table.concat(activeStage2, "\n") .. (#activeStage2 > 0 and "\n" or "")
    )
end

--[[
    Writes failed items to the output file.
    @param processName string - The name of the process
    @param outputDir string - The output directory
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
]]
ProcessUtil.WriteFailedItems = function(
    processName: string, 
    outputDir: string,
    openCloudClient: OpenCloudClient.OpenCloudClient
) : ()
    -- Get the failed items ordered data store and failed item logs map
    local failedItemsOrderedDataStoreName = Constants.BatchProcessFailedItemsOrderedDataStorePrefix .. processName
    local failedItemLogsMapName = Constants.BatchProcessFailedItemLogsMapPrefix .. processName

    -- Loop over all of the failed items
    repeat
        local page = openCloudClient.getOrderedDataStoreRange(failedItemsOrderedDataStoreName, "global", true, 100, nil, nextTimestamp, nil)
        if page.status ~= 200 then
            FileIO.AppendToCLILogFile(processName, outputDir, "Warning: Failed to get failed items. Reason: " .. OpenCloudClient.GetBodyAsString(page))
            return
        end
        if page.body.orderedDataStoreEntries == nil then
            break
        end
        for _, failedItem in ipairs(page.body.orderedDataStoreEntries) do
            -- Get the failed item logs
            local failedItemLogs = openCloudClient.getSortedMapEntry(failedItemLogsMapName, failedItem.id)
            if failedItemLogs.status ~= 200 and failedItemLogs.status ~= 404 then
                FileIO.AppendToCLILogFile(processName, outputDir, "Warning: Failed to get failed item logs. Reason: " .. OpenCloudClient.GetBodyAsString(failedItemLogs))
                return
            end

            -- If the failed item logs are not found, write just the failed item to the file
            if failedItemLogs.status == 404 then
                local failedItemLine = failedItem.id .. "|Could not load the failed item's error log and session path. Please re-run the callback on the item to diagnose."
                FileIO.AppendLineToFile(outputDir .. '/' .. processName .. '/' .. Constants.FailedItemsFile, failedItemLine)
                continue
            end

            -- Otherwise, write the failed item and logs to the file
            local failedItemData: Types.FailedItem = failedItemLogs.body.value
            local failedItemLine = string.format(
                "%s|%s|%s|%s",
                failedItem.id,
                TimeUtil.FormatTimestamp(failedItemData.time),
                failedItemData.error,
                failedItemData.sessionPath
            )
            FileIO.AppendLineToFile(outputDir .. '/' .. processName .. '/' .. Constants.FailedItemsFile, failedItemLine)

            local deleteFailedItemLog = openCloudClient.deleteSortedMapEntry(failedItemLogsMapName, failedItem.id)
            if deleteFailedItemLog.status ~= 200 then
                FileIO.AppendToCLILogFile(processName, outputDir, "Warning: Failed to delete failed item log for " .. failedItem.id .. ". Reason: " .. OpenCloudClient.GetBodyAsString(deleteFailedItemLog))
            end
        end
        nextTimestamp = page.body.orderedDataStoreEntries[#page.body.orderedDataStoreEntries].value + 1
    until page.body.nextPageToken == nil
end

--[[
    Writes the batch process to the output file.
    @param processName string - The name of the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
    @param outputDir string - The output directory
]]
ProcessUtil.WriteBatchProcess = function(
    processName: string, 
    openCloudClient: OpenCloudClient.OpenCloudClient, 
    outputDir: string
): ()
    local batchProcess = openCloudClient.getSortedMapEntry(
        Constants.BatchProcessMapName, 
        processName
    )
    if batchProcess.status ~= 200 then
        FileIO.AppendToCLILogFile(processName, outputDir, "Warning: Failed to get batch process information. Reason: " .. OpenCloudClient.GetBodyAsString(batchProcess))
        return
    end
    local values = batchProcess.body.value
    local batchProcessHeader = TableUtil.FormatHeader(
        'Process Name',
        'Create Time',
        'Last Update Time',
        'Status',
        'Scanned',
        'Processed',
        'Failed'
    )
    local batchProcessSeparator = TableUtil.FormatSeparator(7)
    local batchProcessLine = TableUtil.FormatLine(
        processName,
        TimeUtil.FormatTimestamp(values.startTime),
        TimeUtil.FormatTimestamp(values.updateTime),
        values.status,
        values.scannedItems,
        values.processedItems,
        values.failedItems
    )
    local batchProcessBody = string.format(
        "%s\n%s\n%s\n\nConfigurations:\n---------------\n%s",
        batchProcessHeader,
        batchProcessSeparator,
        batchProcessLine,
        serde.encode("json", batchProcess.body.value.configs, true)
    )
    FileIO.WriteFile(outputDir .. '/' .. processName .. '/' .. Constants.BatchProcessFile, batchProcessBody)
end

--[[
    Sends a stop signal to the batch processing session tasks.
    @param processName string - The name of the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
    @param configs Types.AnyConfigs - The configurations for the process
]]
ProcessUtil.StopSessionTasks = function(processName: string, openCloudClient: OpenCloudClient.OpenCloudClient, configs: Types.AnyConfigs): ()
    CLIO.Print("Stopping all session tasks (this may take up to 5 minutes)...")

    local process = openCloudClient.getSortedMapEntry(
        Constants.BatchProcessMapName, 
        processName
    )
    if process.status == 404 then
        return
    elseif process.status ~= 200 then
        CLIO.Error("There was an error checking the process info. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(process))
    end
    local processInfo: Types.BatchProcess = process.body.value

    -- Only stop if the process is in progress
    if processInfo.status ~= "InProgress" then
        return
    end

    -- Send the stop signal to the process
    processInfo.status = "Stopped"
    local updateResult = openCloudClient.updateSortedMapEntry(
        Constants.BatchProcessMapName, 
        processName,
        processInfo,
        nil,
        configs.memoryStoresExpiration
    )
    if updateResult.status ~= 200 then
        CLIO.Error("There was an error stopping the process. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(updateResult))
    end
end

--[[
    Waits for all session tasks for a batch processing operation to complete.
    @param processName string - The name of the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
]]
ProcessUtil.WaitForSessionsToComplete = function(processName: string, openCloudClient: OpenCloudClient.OpenCloudClient): ()
    -- Get the process task status
    local processTaskStatus = openCloudClient.getSortedMapEntry(
        Constants.BatchProcessTaskStatusMapName, 
        processName
    )
    if processTaskStatus.status == 404 then
        return
    elseif processTaskStatus.status ~= 200 then
        CLIO.Error("There was an error checking the process task status. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(processTaskStatus))
    end
    local status: Types.ProcessTaskStatus = processTaskStatus.body.value

    local completedSessions = {
        stage1 = {},
        stage2 = {}
    }

    while true do
        local allSessionsCompleted = true
        for _, stage1SessionPath in ipairs(status.stage1SessionPaths) do
            if completedSessions.stage1[stage1SessionPath] then
                continue
            end

            -- Check the status of the stage 1 session task
            local getStage1Status = openCloudClient.getLuauExecutionSessionStatus(stage1SessionPath)
            if getStage1Status.status ~= 200 and getStage1Status.status ~= 404 then
                CLIO.Error("There was an error checking the status of session task with path " .. stage1SessionPath .. ". Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(getStage1Status))
            end
            if getStage1Status.body and getStage1Status.body.state == "PROCESSING" then
                allSessionsCompleted = false
            else
                table.insert(completedSessions.stage1, stage1SessionPath)
            end
        end

        -- Check all stage 2 tasks
        for _, stage2SessionPath in ipairs(status.stage2SessionPaths) do
            if completedSessions.stage2[stage2SessionPath] then
                continue
            end

            -- Check the status of the stage 2 session task
            local getStage2Status = openCloudClient.getLuauExecutionSessionStatus(stage2SessionPath)
            if getStage2Status.status ~= 200 and getStage2Status.status ~= 404 then
                CLIO.Error("There was an error checking the status of session task with path " .. stage2SessionPath .. ". Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(getStage2Status))
            end
            if getStage2Status.body and getStage2Status.body.state == "PROCESSING" then
                allSessionsCompleted = false
            else
                table.insert(completedSessions.stage2, stage2SessionPath)
            end
        end

        -- If all sessions are completed, break the loop
        if allSessionsCompleted then
            break
        end

        task.wait(READ_TASK_STATUS_INTERVAL)
    end
end

--[[
    Exits the batch process and finalizes the output.
    @param processName string - The name of the process
    @param configs Types.AnyConfigs - The configurations for the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
]]
ProcessUtil.FinalizeOnExit = function(processName: string, configs: Types.AnyConfigs, openCloudClient: OpenCloudClient.OpenCloudClient): ()
    ProcessUtil.StopSessionTasks(processName, openCloudClient, configs)
    ProcessUtil.WaitForSessionsToComplete(processName, openCloudClient)

    CLIO.Print("Writing output files...")
    ProcessUtil.WriteFailedItems(processName, configs.outputDirectory, openCloudClient)
    ProcessUtil.WriteBatchProcess(processName, openCloudClient, configs.outputDirectory)
    ProcessUtil.ExpireStage1SessionTasks(processName, configs, openCloudClient)
    ProcessUtil.ExpireStage2SessionTasks(processName, configs, openCloudClient)
    pcall(function()
        fs.removeFile(configs.outputDirectory .. "/" .. processName .. "/" .. Constants.ActiveStage1TasksFile)
    end)
    pcall(function()
        fs.removeFile(configs.outputDirectory .. "/" .. processName .. "/" .. Constants.ActiveStage2TasksFile)
    end)
    CLIO.Print("Done!")
end

return ProcessUtil
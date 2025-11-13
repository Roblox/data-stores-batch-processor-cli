--!strict

--[[
    Command for monitoring the batch process.
]]

-- Native Libraries
local datetime = require('@lune/datetime')
local process = require('@lune/process')
local task = require('@lune/task')

-- Local Libraries
local CLIO = require('../util/clio')
local Constants = require('../shared/constants')
local FileIO = require('../util/fileio')
local OpenCloudClient = require('../util/open-cloud-client')
local ProcessUtil = require('../util/process-util')
local Stage1Util = require('../util/stage1-util')
local Stage2Util = require('../util/stage2-util')
local Types = require('../shared/types')

-- Constants
local LOOP_INTERVAL = 1
local PROGRESS_UPDATE_LOOP_INTERVAL = 5
local RESTART_SESSION_TASK_LOOP_INTERVAL = 1
local EXPIRE_STAGE_1_SESSION_TASK_LOOP_INTERVAL = 5
local EXPIRE_STAGE_2_SESSION_TASK_LOOP_INTERVAL = 60
local WRITE_FAILED_ITEMS_LOOP_INTERVAL = 60
local WRITE_BATCH_PROCESS_LOOP_INTERVAL = 5
local TIME_BEFORE_AUTOMATIC_FAILURE = 600
local WINDOW_SIZE = 60

-- Global variables
local lastScannedItemsUpdate = datetime.now().unixTimestamp
local lastScannedItems = 0
local scannedItemsWindow = {}
local processedItemsWindow = {}

--[[
    Calculates the rates of scanned and processed items. It does this using a sliding window of entries on each update. 
    The lower bound of the window in terms of time can be roughly calcualted as WINDOW_SIZE * PROGRESS_UPDATE_LOOP_INTERVAL, 
    but it is not exact.
    @param scannedItems number - The number of scanned items
    @param processedItems number - The number of processed items
    @return (number, number) - The rate of scanned items and the rate of processed items
]]
local function calculateRates(scannedItems: number, processedItems: number): (number, number)
    local currentUnixTimestamp = datetime.now().unixTimestamp

    -- Update the scanned items tracker
    local nextScannedItemsElement = {
        unixTimestamp = currentUnixTimestamp,
        scannedItems = scannedItems
    }
    table.insert(scannedItemsWindow, nextScannedItemsElement)
    local scannedItemsRate = math.round((scannedItems - scannedItemsWindow[1].scannedItems) / (currentUnixTimestamp - scannedItemsWindow[1].unixTimestamp) * 60)

    -- Update the processed items tracker
    local nextProcessedItemsElement = {
        unixTimestamp = currentUnixTimestamp,
        processedItems = processedItems
    }
    table.insert(processedItemsWindow, nextProcessedItemsElement)
    local processedItemsRate = math.round((processedItems - processedItemsWindow[1].processedItems) / (currentUnixTimestamp - processedItemsWindow[1].unixTimestamp) * 60)

    -- Remove the oldest element if the tracker is too long
    if #processedItemsWindow > WINDOW_SIZE then
        table.remove(processedItemsWindow, 1)
    end
    if #scannedItemsWindow > WINDOW_SIZE then 
        table.remove(scannedItemsWindow, 1)
    end

    return scannedItemsRate, processedItemsRate
end

--[[
    Monitors the batch process.
    @param processName string - The name of the process to monitor
    @param configs Types.AnyConfigs - The configurations for the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
    @return string? - The status of the process, or nil if the process is not done
]]
local function progressUpdate(
    processName: string, 
    configs: Types.AnyConfigs, 
    openCloudClient: OpenCloudClient.OpenCloudClient
): string?
    -- Get the process info from the batch process map with error handling
    local processInfo: Types.OpenCloudResponse = openCloudClient.getSortedMapEntry(
        Constants.BatchProcessMapName, 
        processName
    )
    if processInfo.status == 500 or processInfo.status == 429 then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Error: There was a critical Open Cloud error. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(processInfo))
        CLIO.Error("There was a critical Open Cloud error. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(processInfo), function()
            ProcessUtil.FinalizeOnExit(processName, configs, openCloudClient)
        end)
    end
    if processInfo.status ~= 200 then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Warning: Failed to get batch process information. Reason: " .. OpenCloudClient.GetBodyAsString(processInfo))
        return nil
    end
    local values: Types.BatchProcess = processInfo.body.value

    -- Check if the process is stuck
    if not values.listingComplete and values.scannedItems == lastScannedItems then
        if datetime.now().unixTimestamp - lastScannedItemsUpdate > TIME_BEFORE_AUTOMATIC_FAILURE then
            FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Warning: The process is stuck. Please check your stage 1 logs at " .. configs.outputDirectory .. "/" .. processName .. "/session_logs/stage1 to diagnose the issue.")
            CLIO.Error("The process is stuck. Please check your stage 1 logs at " .. configs.outputDirectory .. "/" .. processName .. "/session_logs/stage1 to diagnose the issue.", function()
                ProcessUtil.FinalizeOnExit(processName, configs, openCloudClient)
            end)
        end
    else
        lastScannedItems = values.scannedItems
        lastScannedItemsUpdate = datetime.now().unixTimestamp
    end

    -- Calculate the rates
    local scannedItemsRate, processedItemsRate = calculateRates(values.scannedItems, values.processedItems)

    -- Update the CLI with the latest progress
    CLIO.PrintProgressLine(
        processName, 
        values.startTime, 
        values.updateTime, 
        values.status, 
        values.scannedItems .. " (" .. scannedItemsRate .. "/min)", 
        values.processedItems .. " (" .. processedItemsRate .. "/min)", 
        values.failedItems
    )

    return values.status
end

--[[
    Starts or restarts Session Tasks that may have died.
    @param processName string - The name of the process
    @param scanType Types.ScanType - The type of scan to perform
    @param configs Types.AnyConfigs - The configurations for the process
    @param openCloudClient OpenCloudClient.OpenCloudClient - The open cloud client
]]
local function restartSessionTask(
    processName: string, 
    scanType: Types.ScanType, 
    configs: Types.AnyConfigs, 
    openCloudClient: OpenCloudClient.OpenCloudClient
): ()
    -- Get the process task status with error handling
    local processTaskStatus = openCloudClient.getSortedMapEntry(
        Constants.BatchProcessTaskStatusMapName, 
        processName
    )
    if processTaskStatus.status == 500 or processTaskStatus.status == 429 then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Error: There was a critical Open Cloud error. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(processTaskStatus))
        CLIO.Error("There was a critical Open Cloud error. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(processTaskStatus), function()
            ProcessUtil.FinalizeOnExit(processName, configs, openCloudClient)
        end)
    end
    if processTaskStatus.status ~= 200 then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Warning: Failed to get process task status. Reason: " .. OpenCloudClient.GetBodyAsString(processTaskStatus))
        return
    end
    local status: Types.ProcessTaskStatus = processTaskStatus.body.value

    -- Start stage 1 task
    if #status.stage1SessionPaths < 1 then
        Stage1Util.CreateSessionTask(scanType, processName, status, configs, openCloudClient)
        return
    end

    -- Start stage 2 task
    if #status.stage2SessionPaths < (tonumber(status.numInstances :: string) or 1) then
        Stage2Util.CreateSessionTask(processName, status, configs, openCloudClient)
    end
end

-- Monitor
local Monitor = {}

--[[
    Monitors the batch process.
    @param processName string - The name of the process to monitor
    @param scanType Types.ScanType - The type of scan to perform
    @param configs Types.AnyConfigs - The configurations for the process
    @param initialProcessInfo Types.BatchProcess? - The initial process info, or nil if the process is not resuming
]]
Monitor.Execute = function(
    processName: string, 
    scanType: Types.ScanType, 
    configs: Types.AnyConfigs,
    initialProcessInfo: Types.BatchProcess?
): ()
    FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Info: Starting Monitor Loop.")
    local openCloudClient = OpenCloudClient.CreateOpenCloudClient(
        process.env['API_KEY'], 
        configs.universeId
    )

    -- Print progress header and separator
    CLIO.PrintProgressHeader(processName, initialProcessInfo ~= nil)
    CLIO.PrintProgressLine(processName, 0, 0, 'Starting', 0, 0, 0)

    -- Try to resume from where we left off
    if initialProcessInfo then
        scannedItemsWindow = { { unixTimestamp = datetime.now().unixTimestamp, scannedItems = initialProcessInfo.scannedItems } }
        processedItemsWindow = { { unixTimestamp = datetime.now().unixTimestamp, processedItems = initialProcessInfo.processedItems } }
        restartSessionTask(processName, scanType, configs, openCloudClient)
    else
        scannedItemsWindow = { { unixTimestamp = datetime.now().unixTimestamp, scannedItems = 0 } }
        processedItemsWindow = { { unixTimestamp = datetime.now().unixTimestamp, processedItems = 0 } }
    end
  
    -- Monitor Loop
    local counter = 0
    local status: string? = nil
    while true do
        counter += LOOP_INTERVAL

        -- Progress Update Loop
        if counter % PROGRESS_UPDATE_LOOP_INTERVAL == 0 then
            status = progressUpdate(processName, configs, openCloudClient)
            if status and status ~= "InProgress" then
                break
            end
        end

        -- Expire Session Tasks Loop
        if counter % EXPIRE_STAGE_1_SESSION_TASK_LOOP_INTERVAL == 0 then
            ProcessUtil.ExpireStage1SessionTasks(processName, configs, openCloudClient)
        end

        if counter % EXPIRE_STAGE_2_SESSION_TASK_LOOP_INTERVAL == 0 then
            ProcessUtil.ExpireStage2SessionTasks(processName, configs, openCloudClient)
        end

        -- Restart Session Tasks Loop
        if counter % RESTART_SESSION_TASK_LOOP_INTERVAL == 0 then
            restartSessionTask(processName, scanType, configs, openCloudClient)
        end

        -- Write Failed Items Loop
        if counter % WRITE_FAILED_ITEMS_LOOP_INTERVAL == 0 then
            ProcessUtil.WriteFailedItems(processName, configs.outputDirectory, openCloudClient)
        end

        -- Write Batch Process Loop
        if counter % WRITE_BATCH_PROCESS_LOOP_INTERVAL == 0 then
            ProcessUtil.WriteBatchProcess(processName, openCloudClient, configs.outputDirectory)
        end
        
        -- Wait before next update
        task.wait(LOOP_INTERVAL)
    end

    -- Complete the process
    if status == "Done" then
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Info: Process completed successfully.")
        CLIO.Complete(processName, configs.outputDirectory)
    else
        FileIO.AppendToCLILogFile(processName, configs.outputDirectory, "Info: Process failed.")
        CLIO.Failed(processName, configs.outputDirectory)
    end
end

return Monitor
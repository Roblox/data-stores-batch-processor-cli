--!strict

--[[
    Command for stopping a batch processing operation.
]]

-- Native Libraries
local process = require('@lune/process')

-- Local Libraries
local CLIO = require('../util/clio')
local ConfigValidators = require('../config/validators')
local Constants = require('../shared/constants')
local OpenCloudClient = require('../util/open-cloud-client')
local Types = require('../shared/types')

-- List
local List = {}

--[[
    Lists all batch processes.
    @param configs Types.ListConfigs - The configurations for the process
]]
List.Execute = function(configs: Types.ListConfigs): ()
     local openCloudClient = OpenCloudClient.CreateOpenCloudClient(process.env['API_KEY'], configs.universeId)

    -- Validate the API Key
    local validateAPIKeySuccess: boolean, validateAPIKeyErrorMessage: string? = ConfigValidators.ValidateAPIKey(openCloudClient, process.env['API_KEY'])
    if not validateAPIKeySuccess then
        CLIO.Error(validateAPIKeyErrorMessage :: string)
        return
    end

     -- loop over all of the batch processes in data stores
    local cursor = ""
    local uniqueBatchProcesses = {}
    repeat
        local page = openCloudClient.listDataStoreEntries(Constants.BatchProcessMapName, "global", 1, cursor)
        if page.status == 404 then
            break
        elseif page.status ~= 200 then
            CLIO.Error("There was an error listing the batch processes. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(page))
            return
        end

        if not page.body or not page.body.dataStoreEntries then
            break
        end

        for _, batchProcess in ipairs(page.body.dataStoreEntries) do
            uniqueBatchProcesses[batchProcess.id] = true
        end
        cursor = page.body.nextPageToken
    until cursor == nil or cursor == ""

    -- loop over all of the batch processes in memory stores
    cursor = ""
    repeat
        local page = openCloudClient.getSortedMapRange(Constants.BatchProcessMapName, true, 200, cursor)
        if page.status ~= 200 then
            CLIO.Error("There was an error listing the batch processes. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(page))
            return
        end
        for _, batchProcess in ipairs(page.body.items) do
            local processInfo: Types.BatchProcess = batchProcess.value
            if not uniqueBatchProcesses[processInfo.name] then
                -- If the process is not in data stores, try to backup the process to data stores
                local backupProcessToDataStores = openCloudClient.createDataStoreEntry(Constants.BatchProcessMapName, "global", processInfo.name, processInfo)
                if backupProcessToDataStores.status ~= 200 then
                    CLIO.Error("There was an error backing up the process to data stores. Please try again later. Reason: " .. OpenCloudClient.GetBodyAsString(backupProcessToDataStores))
                end
                uniqueBatchProcesses[processInfo.name] = true
            end
        end
        cursor = page.body.nextPageToken
    until cursor == nil or cursor == ""

    -- Extract the batch process names
    local batchProcessNames = {}
    for name, _ in pairs(uniqueBatchProcesses) do
        table.insert(batchProcessNames, name)
    end

    if #batchProcessNames == 0 then
        CLIO.Print("No batch processes found.")
    else
        CLIO.PrintBatchProcessList(batchProcessNames)
    end
end

return List
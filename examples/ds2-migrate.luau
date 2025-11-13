--[[
  This script will:
  - Migrate the latest version of the DS2 data store to the migrated data store,
  - Delete all of the entries in the DS2 data store except for the latest version.

  This script migrates the latest version of the DS2 data store to the migrated data store,
  and keeps the latest version in the DS2 data store in case a creator wants to rollback.
]]
local DataStoreService = game:GetService("DataStoreService")
local MIGRATED_DS_SCOPE = "global" -- Change to a different scope as needed

-- Wait for sufficient data store budget
local function waitForBudgetAsync(requestType: Enum.DataStoreRequestType, minBudget: number): ()
    while true do
        local budget = DataStoreService:GetRequestBudgetForRequestType(requestType)
        if budget >= minBudget then
            return
        end
        task.wait(0.5) -- Wait 0.5 second before checking again
    end
end

return function(dataStoreName)
    -- Parse the datastore name
    local ds2Key, playerIdString = string.match(dataStoreName, "^(.*)/([^/]*)$")

    if not ds2Key or not playerIdString then
        error("Invalid Data Store Name: " .. dataStoreName)
    end

    local playerId = tonumber(playerIdString)

    -- Initialize data stores
    local ds2SDS = DataStoreService:GetDataStore(dataStoreName)
    local ds2ODS = DataStoreService:GetOrderedDataStore(dataStoreName)
    local migratedDS = DataStoreService:GetDataStore(ds2Key, MIGRATED_DS_SCOPE)

    -------------
    -- MIGRATE --
    -------------

    -- Modified from BerezaaMethodDataMigrationTool
    local migratedData = migratedDS:GetAsync(playerId)
    if migratedData == nil then
        waitForBudgetAsync(Enum.DataStoreRequestType.GetSortedAsync, 1)
        local pages = ds2ODS:GetSortedAsync(false, 1)

        -- Get the latest version
        local latestVersion = pages:GetCurrentPage()[1]
        if latestVersion then
            -- Get the data value from the SDS
            local version = latestVersion.value
            waitForBudgetAsync(Enum.DataStoreRequestType.GetAsync, 2)
            local data = ds2SDS:GetAsync(version)

            -- Move this data into the new SDS
            waitForBudgetAsync(Enum.DataStoreRequestType.SetIncrementAsync, 1)
            migratedDS:UpdateAsync(playerId, function(oldData)
                if oldData then
                    return oldData
                end
                return data
            end)
        end
        print("Info: Migrated latest version from " .. dataStoreName .. " to " .. ds2Key .. ".")
    else
        print("Info: Data already exists for player " .. playerId .. " in " .. ds2Key .. ".")
    end
end
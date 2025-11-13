--[[
  This script will:
  - Migrate the latest version of the DS2 data store to the migrated data store,
  - Delete the entire DS2 data store.

  This script deletes the entire DS2 data store, so use with caution.
]]
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MIGRATED_DS_SCOPE = "global" -- Change to a different scope as needed
local UNIVERSE_ID = -1 -- Change to the universe id

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
    -- See https://create.roblox.com/store/asset/100741523916104/BETA-Berezaa-Method-Data-Migration-Tool
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

    ------------
    -- DELETE --
    ------------

    -- Delete the data store
    local encodedDataStoreName = HttpService:UrlEncode(dataStoreName)
    local apiKey = HttpService:GetSecret("DS_DELETION_API_KEY")
    local response = HttpService:RequestAsync({
        Url = "https://apis.roblox.com/cloud/v2/universes/" .. UNIVERSE_ID .. "/data-stores/" .. encodedDataStoreName,
        Method = "DELETE",
        Headers = {
            ["x-api-key"] = apiKey,
            ["Content-Type"] = "application/json",
        },
    })

    if response.StatusCode ~= 200 then
        error("Failed to delete data store. Status code: " .. response.StatusCode .. ", Status message: " .. response.StatusMessage .. ", Body: " .. response.Body)
    end
    print("Info: Deleted data store: " .. dataStoreName)
end
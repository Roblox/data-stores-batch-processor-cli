--!strict

--[[
    A selective library for interacting with Roblox Open Cloud APIs.
]]

-- Native Libraries
local net = require('@lune/net')
local serde = require('@lune/serde')

-- Local Libraries
local RetryUtil = require('./retry-util')
local Types = require('../shared/types')

-- Open Cloud Client
local OpenCloudClient = {}

--[[
    Open Cloud Client type definition.
    Defines the interface for Open Cloud API interactions.
]]
export type OpenCloudClient = {
    getSortedMapEntry: (mapName: string, key: string) -> Types.OpenCloudResponse,
    getSortedMapRange: (
        mapName: string, 
        ascending: boolean,
        pageSize: number?, 
        pageToken: string?,
        exclusiveLowerBound: { ["key"]: string, ["sortKey"]: any }?,
        exclusiveUpperBound: { ["key"]: string, ["sortKey"]: any }?
    ) -> Types.OpenCloudResponse,
    createSortedMapEntry: (
        mapName: string,
        key: string,
        value: any,
        sortKey: any,
        ttl: number
    ) -> Types.OpenCloudResponse,
    deleteSortedMapEntry: (
        mapName: string,
        key: string
    ) -> Types.OpenCloudResponse,
    updateSortedMapEntry: (
        mapName: string,
        key: string,
        value: any,
        sortKey: any,
        ttl: number
    ) -> Types.OpenCloudResponse,
    getLuauExecutionSessionStatus: (sessionPath: string) -> Types.OpenCloudResponse,
    getLuauExecutionSessionLogs: (sessionPath: string) -> Types.OpenCloudResponse,
    createDataStoreEntry: (
        dataStoreName: string,
        scope: string,
        key: string,
        value: any
    ) -> Types.OpenCloudResponse,
    getDataStoreEntry: (
        dataStoreName: string,
        scope: string,
        key: string
    ) -> Types.OpenCloudResponse,
    listDataStoreEntries: (
        dataStoreName: string,
        scope: string,
        pageSize: number?,
        pageToken: string?,
        prefix: string?
    ) -> Types.OpenCloudResponse,
    getOrderedDataStoreRange: (
        orderedDataStoreName: string,
        scope: string,
        ascending: boolean,
        pageSize: number?,
        pageToken: string?,
        inclusiveLowerBound: number?,
        inclusiveUpperBound: number?
    ) -> Types.OpenCloudResponse
}

-- Constants
local BASE_URL = "https://apis.roblox.com/cloud/v2"
local MEMORY_STORE_SORTED_MAP_ITEMS_PATTERN = "%s/universes/%d/memory-store/sorted-maps/%s/items"
local STANDARD_DATA_STORE_ENTRIES_PATTERN = "%s/universes/%d/data-stores/%s/scopes/%s/entries"
local STANDARD_DATA_STORE_NO_SCOPE_PATTERN = "%s/universes/%d/data-stores/%s/entries"
local ORDERED_DATA_STORE_ENTRIES_PATTERN = "%s/universes/%d/ordered-data-stores/%s/scopes/%s/entries"

--[[
    Helper function to make HTTP requests.
    @param method string - The HTTP method to use
    @param url string - The URL to make the request to
    @param headers {[string]: string} - The headers to include in the request
    @param body any - The optional body to include in the request
    @return Types.OpenCloudResponse - The response status and decoded body
]]
local function makeRequest(
    method: string, 
    url: string, 
    headers: {[string]: string}, 
    body: any
): Types.OpenCloudResponse
    local _, result = RetryUtil.RetryAsync(function()
        local response = net.request({
            method = method,
            url = url,
            headers = headers,
            body = body and serde.encode("json", body) or nil
        })
        
        local parseSuccess: boolean, tryParseBody: any = pcall(serde.decode, "json", response.body)
        if response.statusCode >= 200 and response.statusCode < 500 and response.statusCode ~= 429 then
            return {
                status = response.statusCode,
                body = parseSuccess and tryParseBody or response.body
            }
        else
            error({
                status = response.statusCode,
                body = parseSuccess and tryParseBody or response.body
            })
        end
    end)
    
    return result
end

--[[
    Builds a query string from a table of query parameters.
    @param queryParams {[string]: any} - The query parameters to build
    @return string - The query string
]]
local function buildQueryParams(queryParams: {[string]: any}): string
    local queryString = ""
    
    -- Append query parameters to URL
    local first = true
    for key, value in pairs(queryParams) do
        if first then
            queryString = queryString .. "?"
            first = false
        else
            queryString = queryString .. "&"
        end
        queryString = queryString .. string.format(
            "%s=%s", 
            net.urlEncode(key), 
            net.urlEncode(tostring(value))
        )
    end
    return queryString
end

--[[
    Gets the body of an Open Cloud response as a string.
    @param response Types.OpenCloudResponse - The response to get the body from
    @return string - The body of the response
]]
OpenCloudClient.GetBodyAsString = function(response: Types.OpenCloudResponse): string
    return serde.encode("json", response.body)
end

--[[
    Creates a new Open Cloud Client instance.
    @param apiKey string - The API key to use for authentication
    @param universeId number | string - The universe ID to operate on
    @return OpenCloudClient - The created client instance
]]
OpenCloudClient.CreateOpenCloudClient = function(
    apiKey: string, 
    universeId: number | string
): OpenCloudClient
    local defaultHeaders = {
        ["x-api-key"] = apiKey,
        ["Content-Type"] = "application/json"
    }
    
    local client = {}
    
    --[[
        Gets a single value from a SortedMap by key.
        @param mapName string - The name of the SortedMap
        @param key string - The key to get the value for
        @return {status: number, body: any} - The response status and value at the specified key
    ]]
    function client.getSortedMapEntry(mapName: string, key: string): Types.OpenCloudResponse
        local url = string.format(
            MEMORY_STORE_SORTED_MAP_ITEMS_PATTERN .. "/%s",
            BASE_URL,
            universeId,
            net.urlEncode(mapName),
            net.urlEncode(key)
        )
        
        return makeRequest("GET", url, defaultHeaders)
    end
    
    --[[
        Gets a range of values from a SortedMap.
        @param mapName string - The name of the SortedMap
        @param ascending boolean - Whether to sort in ascending order
        @param pageSize number? - The optional maximum number of items to return
        @param pageToken string? - The optional token for pagination
        @param exclusiveLowerBound { ["key"]: string, ["sortKey"]: any }? - The optional exclusive lower bound
        @param exclusiveUpperBound { ["key"]: string, ["sortKey"]: any }? - The optional exclusive upper bound
        @return Types.OpenCloudResponse - The response status and range of values
    ]]
    function client.getSortedMapRange(
        mapName: string, 
        ascending: boolean,
        pageSize: number?, 
        pageToken: string?,
        exclusiveLowerBound: { ["key"]: string, ["sortKey"]: any }?,
        exclusiveUpperBound: { ["key"]: string, ["sortKey"]: any }?
    ): Types.OpenCloudResponse
        local url = string.format(
            MEMORY_STORE_SORTED_MAP_ITEMS_PATTERN,
            BASE_URL,
            universeId,
            net.urlEncode(mapName)
        )

        -- build the filter from the exclusive lower and upper bounds
        local function buildFilter(exclusiveLowerBound: { ["key"]: string, ["sortKey"]: any }?, exclusiveUpperBound: { ["key"]: string, ["sortKey"]: any }?): string
            local filter = ""
            if exclusiveLowerBound then
                if exclusiveLowerBound.key then
                filter = filter .. string.format("id > \"%s\" && ", exclusiveLowerBound.key)
                end
                if exclusiveLowerBound.sortKey then
                    if typeof(exclusiveLowerBound.sortKey) == "number" then
                        filter = filter .. string.format("sortKey > %f && ", exclusiveLowerBound.sortKey)
                    else
                        filter = filter .. string.format("sortKey > \"%s\" && ", exclusiveLowerBound.sortKey)
                    end
                end
            end

            if exclusiveUpperBound then
                if exclusiveUpperBound.key then
                    filter = filter .. string.format("id < \"%s\" && ", exclusiveUpperBound.key)
                end
                if exclusiveUpperBound.sortKey then
                    if typeof(exclusiveUpperBound.sortKey) == "number" then
                        filter = filter .. string.format("sortKey < %f && ", exclusiveUpperBound.sortKey)
                    else
                        filter = filter .. string.format("sortKey < \"%s\" && ", exclusiveUpperBound.sortKey)
                    end
                end
            end

            -- Remove the trailing " && "
            filter = string.sub(filter, 1, -5)
            return filter
        end
       
        -- Build query parameters
        local queryParams = {
            maxPageSize = pageSize or 200,
            pageToken = pageToken or "",
            orderBy = ascending and "asc" or "desc",
            filter = buildFilter(exclusiveLowerBound, exclusiveUpperBound)
        }
        
        url = url .. buildQueryParams(queryParams)
        return makeRequest("GET", url, defaultHeaders)
    end
    
    --[[
        Creates a new entry in a SortedMap.
        @param mapName string - The name of the SortedMap
        @param key string - The key for the new entry
        @param value any - The value to store
        @param sortKey any - The sort key for ordering
        @param ttl number - The time-to-live in seconds
        @return Types.OpenCloudResponse - The response status and created entry
    ]]
    function client.createSortedMapEntry(
        mapName: string,
        key: string,
        value: any,
        sortKey: any,
        ttl: number
    ): Types.OpenCloudResponse
        local url = string.format(
            MEMORY_STORE_SORTED_MAP_ITEMS_PATTERN .. "?id=%s",
            BASE_URL,
            universeId,
            net.urlEncode(mapName),
            net.urlEncode(key)
        )
        
        local body = {
            id = key,
            value = value,
            ttl = string.format("%ds", ttl)
        }

        if not sortKey then
            body.stringSortKey = ""
        elseif typeof(sortKey) == "number" then
            body.numericSortKey = sortKey
        else
            body.stringSortKey = tostring(sortKey)
        end

        return makeRequest("POST", url, defaultHeaders, body)
    end

    --[[
        Deletes an entry from a SortedMap.
        @param mapName string - The name of the SortedMap
        @param key string - The key of the entry to delete
        @return Types.OpenCloudResponse - The response status and nil
    ]]
    function client.deleteSortedMapEntry(mapName: string, key: string): Types.OpenCloudResponse
        local url = string.format(
            MEMORY_STORE_SORTED_MAP_ITEMS_PATTERN .. "/%s",
            BASE_URL,
            universeId,
            net.urlEncode(mapName),
            net.urlEncode(key)
        )

        return makeRequest("DELETE", url, defaultHeaders)
    end
    
    --[[
        Updates an existing entry in a SortedMap.
        @param mapName string - The name of the SortedMap
        @param key string - The key of the entry to update
        @param value any - The new value to store
        @param sortKey any - The new sort key for ordering
        @param ttl number - The new time-to-live in seconds
        @return Types.OpenCloudResponse - The response status and updated entry
    ]]
    function client.updateSortedMapEntry(
        mapName: string,
        key: string,
        value: any,
        sortKey: any,
        ttl: number
    ): Types.OpenCloudResponse
        local url = string.format(
            MEMORY_STORE_SORTED_MAP_ITEMS_PATTERN .. "/%s",
            BASE_URL,
            universeId,
            net.urlEncode(mapName),
            net.urlEncode(key)
        )
        
        local body = {
            value = value,
            ttl = string.format("%ds", ttl),
            stringSortKey = sortKey and tostring(sortKey) or ""
        }
        
        return makeRequest("PATCH", url, defaultHeaders, body)
    end
    
    --[[
        Gets the status of a Luau Execution Session.
        @param sessionPath string - The path of the session to check
        @return Types.OpenCloudResponse - The response status and session status
    ]]
    function client.getLuauExecutionSessionStatus(sessionPath: string): Types.OpenCloudResponse
        local url = string.format(
            "%s/%s",
            BASE_URL,
            sessionPath
        )
        
        return makeRequest("GET", url, defaultHeaders)
    end

     --[[
        Gets the logs of a Luau Execution Session.
        @param sessionPath string - The path of the session to check
        @return Types.OpenCloudResponse - The response status and session status
    ]]
    function client.getLuauExecutionSessionLogs(sessionPath: string): Types.OpenCloudResponse
        local url = string.format(
            "%s/%s/logs",
            BASE_URL,
            sessionPath
        )
        
        return makeRequest("GET", url, defaultHeaders)
    end

    --[[
        Creates an entry in a Standard DataStore.
        @param dataStoreName string - The name of the Standard DataStore
        @param scope string - The scope of the Standard DataStore
        @param key string - The key of the entry to create
        @param value any - The value to store
        @return Types.OpenCloudResponse - The response status and created entry
    ]]
    function client.createDataStoreEntry(
        dataStoreName: string,
        scope: string,
        key: string,
        value: any
    ): Types.OpenCloudResponse
        local url = string.format(
            STANDARD_DATA_STORE_ENTRIES_PATTERN,
            BASE_URL,
            universeId,
            net.urlEncode(dataStoreName),
            net.urlEncode(scope)
        )

        local queryParams = {
            id = key
        }
        url = url .. buildQueryParams(queryParams)

        local body = {
            value = value
        }
        
        return makeRequest("POST", url, defaultHeaders, body)
    end

    --[[
        Gets an entry from a Standard DataStore.
        @param dataStoreName string - The name of the Standard DataStore
        @param scope string - The scope of the Standard DataStore
        @param key string - The key of the entry to get
        @return Types.OpenCloudResponse - The response status and entry
    ]]
    function client.getDataStoreEntry(
        dataStoreName: string,
        scope: string,
        key: string
    ): Types.OpenCloudResponse
        local url = string.format(
            STANDARD_DATA_STORE_ENTRIES_PATTERN .. "/%s",
            BASE_URL,
            universeId,
            net.urlEncode(dataStoreName),
            net.urlEncode(scope),
            net.urlEncode(key)
        )
        
        return makeRequest("GET", url, defaultHeaders)  
    end

    --[[
        Lists entries from a Standard DataStore.
        @param dataStoreName string - The name of the Standard DataStore
        @param scope string - The scope of the Standard DataStore
        @param pageSize number? - The optional maximum number of items to return
        @param pageToken string? - The optional token for pagination
        @param prefix string? - The optional prefix to filter by
        @return Types.OpenCloudResponse - The response status and list of entries
    ]]
    function client.listDataStoreEntries(
        dataStoreName: string,
        scope: string,
        pageSize: number?,
        pageToken: string?,
        prefix: string?
    ): Types.OpenCloudResponse
        local url = ""
        if scope == "" then
            url = string.format(
                STANDARD_DATA_STORE_NO_SCOPE_PATTERN,
                BASE_URL,
                universeId,
                net.urlEncode(dataStoreName)
            )
        else
            url = string.format(
                STANDARD_DATA_STORE_ENTRIES_PATTERN,
                BASE_URL,
                universeId,
                net.urlEncode(dataStoreName),
                net.urlEncode(scope)
            )
        end

        -- build the filter from the prefix
        local function buildFilter(prefix: string): string
            return string.format("id.startsWith(\"%s\")", prefix)
        end

        local queryParams = {
            maxPageSize = pageSize or 200,
            pageToken = pageToken or "",
            filter = prefix and buildFilter(prefix)
        }
        
        url = url .. buildQueryParams(queryParams)
        return makeRequest("GET", url, defaultHeaders)
    end

    --[[
        Gets a range of entries from an OrderedDataStore.
        @param orderedDataStoreName string - The name of the OrderedDataStore
        @param scope string - The scope of the OrderedDataStore
        @param ascending boolean - Whether to sort in ascending order
        @param pageSize number? - The optional maximum number of items to return
        @param pageToken string? - The optional token for pagination
        @param inclusiveLowerBound number? - The optional inclusive lower bound for values
        @param inclusiveUpperBound number? - The optional inclusive upper bound for values
        @return Types.OpenCloudResponse - The response status and range of entries
    ]]
    function client.getOrderedDataStoreRange(
        orderedDataStoreName: string,
        scope: string,
        ascending: boolean,
        pageSize: number?,
        pageToken: string?,
        inclusiveLowerBound: number?,
        inclusiveUpperBound: number?
    ): Types.OpenCloudResponse
        local url = string.format(
            ORDERED_DATA_STORE_ENTRIES_PATTERN,
            BASE_URL,
            universeId,
            net.urlEncode(orderedDataStoreName),
            net.urlEncode(scope or "global")
        )

        -- build the filter from the inclusive lower and upper bounds
        local function buildFilter(inclusiveLowerBound: number?, inclusiveUpperBound: number?): string
            local filter = ""
            if inclusiveLowerBound then
                filter = filter .. string.format("entry >= %d && ", inclusiveLowerBound)
            end

            if inclusiveUpperBound then
                filter = filter .. string.format("entry <= %d && ", inclusiveUpperBound)
            end

            -- Remove the trailing " && "
            filter = string.sub(filter, 1, -5)
            return filter
        end
       
        -- Build query parameters
        local queryParams = {
            maxPageSize = pageSize or 200,
            pageToken = pageToken or "",
            orderBy = not ascending and "value desc" or nil,
            filter = buildFilter(inclusiveLowerBound, inclusiveUpperBound)
        }
        
        url = url .. buildQueryParams(queryParams)
        return makeRequest("GET", url, defaultHeaders)
    end
    
    return client
end

return OpenCloudClient
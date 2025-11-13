--!nolint LocalShadow

local net = require("@lune/net")
local task = require("@lune/task")
local serde = require("@lune/serde")

local utils = require("./utils")

export type TasksError = {
    message: string,
    res: net.FetchResponse?,
}

export type CreateTaskParams = {
    api_key: string,
    universe_id: number | string,
    place_id: number | string,
    place_version: (number | string)?,
}

export type PollTaskOpts = {
    poll_max_attempts: number?,
    poll_wait_seconds: number?,
    on_poll: ((decoded_body: any, full_res: net.FetchResponse) -> nil)?,
}

local m_tasks_client = {}

local function make_request(url: string, headers: { [string]: string }, body: any?): net.FetchResponse
    local max_attempts = 3
    local res = nil

    for i = 1, max_attempts do
        res = net.request({
            url = url,
            headers = headers,
            method = if body == nil then "GET" else "POST",
            body = if body ~= nil then serde.encode("json", body) else nil,
        })

        if res.ok then
            return res
        end

        task.wait(0.5)
    end
    assert(res ~= nil)
    return res
end

function m_tasks_client.create_task(script: string, params: CreateTaskParams): (any?, TasksError?)
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = params.api_key,
    }

    local data = {
        ["script"] = script,
    }

    local url = `https://apis.roblox.com/cloud/v2/universes/{params.universe_id}/places/{params.place_id}/`
    if params.place_version ~= nil then
        url ..= `versions/{params.place_version}/`
    end
    url ..= "luau-execution-session-tasks"

    local res = make_request(url, headers, data)
    if not res.ok then
        return nil, {
            message = "task creation request failed",
            res = res,
        }
    end

    local body = serde.decode("json", res.body)
    if body["path"] == nil then
        return nil,
            {
                message = "task creation response missing expected field: 'path'",
                res = res,
            }
    end

    return body
end

function m_tasks_client.poll_task_completion(api_key: string, path: string, opts: PollTaskOpts?): (any?, TasksError?)
    opts = utils.notnil_or_default(opts, {})
    assert(opts ~= nil)
    local poll_max_attempts = utils.notnil_or_default(opts.poll_max_attempts, -1)
    local poll_wait_seconds = utils.notnil_or_default(opts.poll_wait_seconds, 2)
    local on_poll = utils.notnil_or_default(opts.on_poll, function(_, _) end)

    local headers = {
        ["x-api-key"] = api_key,
    }
    local url = `https://apis.roblox.com/cloud/v2/{path}`

    local attempts = 0
    while poll_max_attempts == -1 or attempts < poll_max_attempts do
        attempts += 1
        local res = make_request(url, headers)

        local res_body = serde.decode("json", res.body)
        if res_body["state"] ~= "PROCESSING" then
            return res_body
        end
        on_poll(res_body, res)

        task.wait(poll_wait_seconds)
    end
    return nil, { message = `max poll attempts reached ({poll_max_attempts})` }
end

function m_tasks_client.fetch_task_logs(api_key: string, taskPath: string): ({ string }?, TasksError?)
    local headers = {
        ["x-api-key"] = api_key,
    }
    local url = `https://apis.roblox.com/cloud/v2/{taskPath}/logs`

    local res = make_request(url, headers)
    if not res.ok then
        return nil, {
            message = "fetch task logs request failed",
            res = res,
        }
    end
    local logs_body = serde.decode("json", res.body)
    local logs_data_list = logs_body["luauExecutionSessionTaskLogs"]
    if logs_data_list == nil then
        return nil,
            {
                message = "fetch task logs request returned unexpected response",
                res = res,
            }
    end
    if #logs_data_list == 0 then
        return {} -- no logs found
    end

    local logs = utils.safe_access(logs_data_list)[1]["messages"]({})
    return logs
end

return m_tasks_client
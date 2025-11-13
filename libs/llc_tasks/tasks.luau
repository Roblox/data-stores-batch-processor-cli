--!nolint LocalShadow

local fs = require("@lune/fs")
local LuaEncode = require("./LuaEncode")
local tasks_client = require("./tasks_client")
local utils = require("./utils")

local m_tasks = {}

export type Error = tasks_client.TasksError
export type CreateTaskParams = tasks_client.CreateTaskParams
export type PollTaskOpts = tasks_client.PollTaskOpts

local function make_task_result(output, path: string, poll_res: any, req_params: CreateTaskParams)
    local res = {
        output = output,
        path = path,
        poll_res = poll_res,
        req_params = req_params,
    }

    function res:fetch_logs(): ({ string }?, Error?)
        self = self :: typeof(res)
        return tasks_client.fetch_task_logs(self.req_params.api_key, self.path)
    end

    return res
end

local function make_task_handle<Rtn>(
    path: string,
    task_create_res: any,
    req_params: CreateTaskParams,
    poll_opts: PollTaskOpts,
    _rtn_sig: Rtn
)
    local handle = {
        path = path,
        task_create_res = task_create_res,
        req_params = req_params,
        poll_opts = poll_opts,
    }

    type TaskResult = typeof(make_task_result(({} :: any) :: Rtn, "", nil, nil :: any))

    function handle:wait(): (TaskResult?, Error?)
        self = self :: typeof(handle)
        local res, err = tasks_client.poll_task_completion(self.req_params.api_key, self.path, self.poll_opts)
        if err ~= nil then
            return nil, err
        end

        local output = utils.safe_access(res)["output"]["results"][1]()

        return make_task_result(output :: Rtn, path, res, req_params)
    end

    return handle
end

function m_tasks.encode_task_from_file(file_path: string, ...): (string?, Error?)
    local task_fn_str = fs.readFile(file_path)
    return m_tasks.encode_task(task_fn_str, ...)
end

function m_tasks.encode_task(task_fn_str: string, ...): (string?, Error?)
    local args = { ... }
    local args_encode = ""
    local ok, err = pcall(function()
        args_encode = LuaEncode(args, { OutputWarnings = false })
    end)
    if not ok then
        return nil, { message = `error encoding args: {err}` }
    end

    local task_encode =
        `function t() {task_fn_str}\nend;\nfunction a() return {args_encode}\nend\nreturn t()(table.unpack(a()))`
    return task_encode
end

function m_tasks.create_from_file(file_path: string, req_params: CreateTaskParams, _fn_sig)
    local task_str = fs.readFile(file_path)
    return m_tasks.create(task_str, req_params, _fn_sig)
end

function m_tasks.create<Rtn, Arg...>(task_str: string, req_params: CreateTaskParams, _fn_sig: ((Arg...) -> Rtn)?)
    local task = {
        task_str = task_str,
        req_params = req_params,
        poll_opts = {} :: PollTaskOpts,
    }

    type TaskHandle = typeof(make_task_handle(
        "",
        nil,
        { api_key = "", universe_id = "", place_id = "" },
        {},
        (nil :: any) :: Rtn
    ))

    function task:start(...: Arg...): (TaskHandle?, Error?)
        self = self :: typeof(task)
        local task_encode, err = m_tasks.encode_task(self.task_str, ...)
        if err ~= nil then
            return nil, err
        end
        assert(task_encode ~= nil)

        local res, err = tasks_client.create_task(task_encode, self.req_params)
        if err ~= nil then
            return nil, err
        end
        assert(res)
        -- create_task would have errored if res had no memeber 'path'
        return make_task_handle(res.path, res, self.req_params, self.poll_opts, (nil :: any) :: Rtn)
    end

    type TaskResult = typeof(make_task_result(({} :: any) :: Rtn, "", nil, nil :: any))
    --- wraps task creation and polling
    function task:call(...: Arg...): (TaskResult?, Error?)
        self = self :: typeof(task)
        local handle, err = self:start(...)
        if err ~= nil then
            return nil, err
        end
        assert(handle ~= nil)
        handle = handle :: TaskHandle
        local res, err = handle:wait()
        if err ~= nil then
            return nil, err
        end
        assert(res ~= nil)
        return res
    end

    return task
end

return m_tasks
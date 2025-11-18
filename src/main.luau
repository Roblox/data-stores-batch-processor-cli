--!strict

--[[
    Main entry point for the batch processor CLI.
    This module handles command line argument parsing, configuration loading,
    and execution of batch processing commands.
]]

-- Native Libraries
local process = require('@lune/process')

-- Local Libraries
local CLI = require('./cli/core')
local CLIO = require('./util/clio')
local ConfigLoader = require('./config/loader')
local Constants = require('./shared/constants')
local Cleanup = require('./commands/cleanup')
local List = require('./commands/list')
local ProcessDataStores = require('./commands/process-data-stores')
local ProcessKeys = require('./commands/process-keys')
local Resume = require('./commands/resume')
local Types = require('./shared/types')

-- Constants
local MAX_PROCESS_NAME_LENGTH = 18

--[[
    Main entry point for the batch processor.
]]
return function(): ()
    -- Parse CLI arguments
    local parsedInput = CLI.Parse()
    local command: Types.CommandType = parsedInput.command
    local processName: string = parsedInput.values.processName
    local options: Types.ConfigValues = parsedInput.values
    local flags: Types.ConfigValues = parsedInput.flags
    local configToOptionFlagMap: { [string]: string } = parsedInput.configToOptionFlagMap
    local inverseFlagMap: { [string]: string } = parsedInput.inverseFlagMap

    -- Validate an API Key is set
    if not process.env['API_KEY'] then
        CLIO.Error('API_KEY is not set. Set the API_KEY environment variable to and then try again.')
    end

    -- Validate the process name length (if applicable)
    if processName and string.len(processName) > MAX_PROCESS_NAME_LENGTH then
        CLIO.Error("Process name can be at most " .. MAX_PROCESS_NAME_LENGTH .. " characters")
    end

    -- Load and validate configurations
    local configs: Types.ConfigValues = ConfigLoader.LoadConfigs(command, options, flags, configToOptionFlagMap, inverseFlagMap)
    ConfigLoader.ValidateConfigs(configs)
    local finalConfigs = ConfigLoader.PromptForMissingConfigs(command, configs)

    -- Execute the appropriate command based on the command type
    if command == Constants.Commands.ProcessKeys then 
        ProcessKeys.Execute(processName, finalConfigs :: Types.ProcessKeysConfigs)
    elseif command == Constants.Commands.ProcessDataStores then
        ProcessDataStores.Execute(processName, finalConfigs :: Types.ProcessDataStoresConfigs)
    elseif command == Constants.Commands.Resume then
        Resume.Execute(processName, finalConfigs :: Types.ResumeConfigs)
    elseif command == Constants.Commands.Cleanup then
        Cleanup.Execute(processName, finalConfigs :: Types.CleanupConfigs)
    elseif command == Constants.Commands.List then
        List.Execute(finalConfigs :: Types.ListConfigs)
    end
end
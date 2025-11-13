--!strict

--[[
    Core CLI functionality for parsing and handling command line arguments.
]]

-- Native Libraries
local process = require('@lune/process')

-- External Libraries
local frkcli = require('../../libs/frkcli/frkcli')

-- Local Libraries
local Constants = require('../shared/constants')

--[[
    Generates the CLI configuration and mappings.
    @return (any, { [string]: string }, { [string]: string }) - Returns the CLI instance and configuration mappings
]]
local function GenerateCLI(): (any, { [string]: string }, { [string]: string })
    local cli = frkcli.new_subcommands('lune run batch-process', 'Data Stores Batch Processing CLI')
    local configToOptionFlagMap: { [string]: string } = {}
    local inverseFlagMap: { [string]: string } = {}

    --[[
        Helper function to add configuration options to a command.
        @param command any - The command to add options to
        @param configs { [string]: Types.ConfigOption } - The configuration options to add
    ]]
    local function addConfigOptions(command, configs: { string }): ()
        for i: number, configName: string in ipairs(configs) do
            -- Get the config option
            local configOption = Constants.ConfigurationOptions[configName]
            if not configOption then
                continue
            end

            -- Add the option to the command
            command:add_option(configOption.option, {
                help = configOption.description,
                aliases = { configOption.shortOption },
                default = Constants.PlaceHolder
            })
            configToOptionFlagMap[configName] = configOption.option
        end
    end

    --[[
        Helper function to add configuration flags to a command.
        @param command any - The command to add flags to
        @param configs { [string]: Types.ConfigFlag } - The configuration flags to add
    ]]
    local function addConfigFlags(command, configs: { string }): ()
        for i: number, configName: string in ipairs(configs) do
            -- Get the config flag
            local configFlag = Constants.ConfigurationFlags[configName]
            if not configFlag then
                continue
            end

            -- Add the flag to the command
            command:add_flag(configFlag.flag, {
                help = configFlag.description
            })
            configToOptionFlagMap[configName] = configFlag.flag

            -- Add the inverse flag to the command if it exists
            if configFlag.flagInverse then
                command:add_flag(configFlag.flagInverse, {
                    help = configFlag.descriptionInverse or ('not (' .. configFlag.description .. ')')
                })
                inverseFlagMap[configFlag.flag] = configFlag.flagInverse
            end
        end
    end

    -- Add each subcommand to the CLI
    for command, commandDetails in Constants.CommandDetails do
        -- Create the subcommand
        local subcommand = cli:add_subcommand(command, commandDetails.description)
        if commandDetails.positionalArgs then
            for _, positionalArg in ipairs(commandDetails.positionalArgs) do
                subcommand:add_positional(positionalArg.name, {
                    help = positionalArg.description,
                })
            end
        end

        -- Add a config option to the subcommand
        subcommand:add_option('config', {
            help = 'The config file to use for the process',
            aliases = { '-c' },
            default = ''
        })

        -- Add subcommand-specific config options and flags
        addConfigOptions(subcommand, commandDetails.configurations)
        addConfigFlags(subcommand, commandDetails.configurations)
    end

    return cli, configToOptionFlagMap, inverseFlagMap
end

-- CLI
local CLI = {}

--[[
    Parses command line arguments into a structured format.
    @return (Types.CommandType, Types.ConfigValues, Types.ConfigValues, { [string]: string }, { [string]: string }) - Returns the parsed command, options, flags, and mappings
]]
CLI.Parse = function(): { [string]: any }
    local cli, configToOptionFlagMap, inverseFlagMap = GenerateCLI()
    -- Parse the arguments
    local res, err = cli:parse(process.args)

    -- If there is an error, print it and exit
    if err then
        error(err)
    end

    -- Return the command, options, and flags
    return { 
        command = res.command, 
        values = res.result.values, 
        flags = res.result.flags, 
        configToOptionFlagMap = configToOptionFlagMap, 
        inverseFlagMap = inverseFlagMap
    }
end

return CLI
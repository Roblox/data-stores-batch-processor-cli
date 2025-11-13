--!strict

--[[
    Configuration loading and management functionality.
]]

-- Local Libraries
local CLIO = require('../util/clio')
local ConfigValidators = require('./validators')
local Constants = require('../shared/constants')
local FileIO = require('../util/fileio')
local Types = require('../shared/types')

--[[
    Gets the empty configs
    @param sortedConfigList { string } - The sorted list of config names
    @return Types.ConfigValues - The default configs
]]
local function getEmptyConfigs(sortedConfigList: { string }): Types.ConfigValues
    local defaultConfigs: Types.ConfigValues = {}
    for _, configName: string in ipairs(sortedConfigList) do
        defaultConfigs[configName] = Constants.PlaceHolder
    end
    return defaultConfigs
end

--[[
    Loads configs from a config file
    @param configs Types.ConfigValues - The current configuration values
    @param configFile string - The path to the config file
]]
local function addConfigsFromConfigFile(
    configs: Types.ConfigValues, 
    configFile: string
): ()
    -- Try to load the configs from the config file
    local tryLoadConfigs: { [string]: any }? = FileIO.ReadJsonFile(configFile)
    if not tryLoadConfigs then
        CLIO.Error("Failed to load config file " .. configFile)
    end

    -- Load the configs from the config file
    local loadedConfigs = tryLoadConfigs :: { [string]: any }

    -- Add the configs from the config file to the current configs
    for configName: string, configValue: any in pairs(configs) do
        if loadedConfigs[configName] ~= nil then
            configs[configName] = tostring(loadedConfigs[configName])
        end
    end
end

--[[
    Adds configs from options and flags to the current configs
    @param configs Types.ConfigValues - The current configuration values
    @param options Types.ConfigValues - The command line options
    @param flags Types.ConfigValues - The command line flags
    @param configToOptionFlagMap { [string]: string } - The map of config names to option flags
    @param inverseFlagMap { [string]: string } - The map of option flags to inverse flags
]]
local function addConfigsFromOptionsAndFlags(
    configs: Types.ConfigValues, 
    options: Types.ConfigValues, 
    flags: Types.ConfigValues, 
    configToOptionFlagMap: { [string]: string }, 
    inverseFlagMap: { [string]: string }
): ()
    -- For all configs
    for configName: string, configValue: any in pairs(configs) do
        -- Get the corresponding option or flag
        local optionOrFlag: string = configToOptionFlagMap[configName]

        -- Check if the config name is in the options
        if options[optionOrFlag] and options[optionOrFlag] ~= Constants.PlaceHolder then
            configs[configName] = options[optionOrFlag]
        end

        -- Check if the config name is in the flags
        if flags[optionOrFlag] ~= nil and flags[optionOrFlag] ~= Constants.PlaceHolder then
            -- Check if the inverse flag is set
            if flags[optionOrFlag] and inverseFlagMap[optionOrFlag] and flags[inverseFlagMap[optionOrFlag] :: string] then
                CLIO.Error("Do not set both --" .. optionOrFlag .. " and --" .. inverseFlagMap[optionOrFlag])
            elseif flags[optionOrFlag] then
                configs[configName] = "true"
            elseif inverseFlagMap[optionOrFlag] and flags[inverseFlagMap[optionOrFlag] :: string] then
                configs[configName] = "false"
            end
        end
    end
end

--[[
    Applies defaults to configs.
    @param configs Types.ConfigValues - The configurations to apply defaults to
]]
local function applyDefaultsToConfigs(configs: Types.ConfigValues): ()
    for configName: string, configValue: any in pairs(configs) do
        -- Only apply defaults if the config is the placeholder value
        if configValue == Constants.PlaceHolder then
            if Constants.ConfigurationOptions[configName] and Constants.ConfigurationOptions[configName].default then
                configs[configName] = tostring(Constants.ConfigurationOptions[configName].default)
            elseif Constants.ConfigurationFlags[configName] and not Constants.ConfigurationFlags[configName].prompt then
                configs[configName] = "false"
            end
            continue
        end
    end
end

--[[
    Removes the configs that are overridden by flags
    @param configs Types.ConfigValues - The configurations to remove the overridden configs from
]]
local function removeOverriddenConfigs(configs: Types.ConfigValues): ()
    for configName: string, configValue: any in pairs(configs) do
        if Constants.ConfigurationFlags[configName] 
            and Constants.ConfigurationFlags[configName].override 
            and configValue == "true" 
            and configs[Constants.ConfigurationFlags[configName].override :: string] then
            configs[Constants.ConfigurationFlags[configName].override :: string] = nil
        end
    end
end

-- ConfigLoader
local ConfigLoader = {}

--[[
    Loads configurations from various sources based on provided options and flags.
    @param command string - The command to load configurations for
    @param options Types.ConfigValues - Command line options
    @param flags Types.ConfigValues - Command line flags
    @param configToOptionFlagMap { [string]: string } - The map of config names to option flags
    @param inverseFlagMap { [string]: string } - The map of option flags to inverse flags
    @return Types.ConfigValues - The loaded configurations
]]
ConfigLoader.LoadConfigs = function(
    command: Types.CommandType, 
    options: Types.ConfigValues, 
    flags: Types.ConfigValues, 
    configToOptionFlagMap: { [string]: string }, 
    inverseFlagMap: { [string]: string }
): Types.ConfigValues
    -- Get default configs
    local configList = Constants.CommandDetails[command].configurations
    local configs: Types.ConfigValues = getEmptyConfigs(configList)

    -- Load configs from config file if provided
    if options.config and options.config ~= '' then
        addConfigsFromConfigFile(configs, options.config)
    end

    -- Add configs from options and flags
    addConfigsFromOptionsAndFlags(
        configs, 
        options, 
        flags, 
        configToOptionFlagMap, 
        inverseFlagMap
    )

    -- Apply defaults to configs
    if command ~= Constants.Commands.Resume then
        applyDefaultsToConfigs(configs)
    end

    -- Remove the configs that are overridden
    removeOverriddenConfigs(configs)

    return configs
end

--[[
    Validates the provided configurations.
    @param configs Types.ConfigValues - The configurations to validate
]]
ConfigLoader.ValidateConfigs = function(configs: Types.ConfigValues): ()
    -- Validate each config
    for configName: string, configValue: any in pairs(configs) do
        -- Skip if the config is the placeholder value
        if configValue == Constants.PlaceHolder then
            continue
        end

        -- Validate the user-provided config
        local validateSuccess, validateResult = ConfigValidators.Validators[configName](configValue)
        if not validateSuccess then
            CLIO.Error(validateResult :: string)
        end
        configs[configName] = validateResult
    end
end

--[[
    Prompts the user for any missing configuration values.
    @param command Types.CommandType - The command to prompt for missing configurations for
    @param configs Types.ConfigValues - The current configuration values
    @return Types.ConfigValues - The complete configuration with user input
]]
ConfigLoader.PromptForMissingConfigs = function(
    command: Types.CommandType, 
    configs: Types.ConfigValues
): Types.ConfigValues
    -- Skip prompting for resume command except for universeId
    if command == Constants.Commands.Resume then
        if configs['universeId'] == Constants.PlaceHolder then
            configs['universeId'] = CLIO.Prompt(Constants.ConfigurationOptions['universeId'].prompt :: string, 
                ConfigValidators.Validators['universeId']
            )
        end
        return configs
    end

    -- Get the proper config list
    local configList = Constants.CommandDetails[command].configurations

    -- Prompt for all configs that have not been provided
    for _, configName: string in ipairs(configList) do
        if configs[configName] == Constants.PlaceHolder then
            if Constants.ConfigurationOptions[configName] then
                configs[configName] = CLIO.Prompt(
                    Constants.ConfigurationOptions[configName].prompt :: string, 
                    ConfigValidators.Validators[configName]
                )
            elseif Constants.ConfigurationFlags[configName] then
                configs[configName] = CLIO.Prompt(
                    Constants.ConfigurationFlags[configName].prompt :: string, 
                    ConfigValidators.Validators[configName]
                )
            end
        end
    end

    return configs
end

return ConfigLoader

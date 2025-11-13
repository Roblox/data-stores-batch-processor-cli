--!strict

--[[
    Command Line I/O utility functions.
]]

-- Native Libraries
local process = require('@lune/process')
local stdio = require('@lune/stdio')

-- Local Libraries
local Formulas = require('./formulas')
local TableUtil = require('./table-util')
local TimeUtil = require('./time-util')
local Types = require('../shared/types')

-- Global Variables
local firstLineOfProgram = true
local lastProgressLine = false

--[[
    Prints spacing to the console.
]]
local function printSpacing(): ()
    if firstLineOfProgram then 
        print()
    end

    if lastProgressLine then 
        print('\n') 
    end
    
    firstLineOfProgram = false
end

-- CLIO
local CLIO = {}

--[[
    Prompts the user for input until the condition is met
    @param message string - The message to print
    @param condition Types.Function - The condition to check
    @return any - The value
--]]
CLIO.Prompt = function(message: string, condition: (string) -> (boolean, any)): any
    printSpacing()

    -- Print the message
    print(message)

    local promptResult = stdio.prompt()
    local value

    -- Repeat until the condition is met
    repeat
        local success, result = condition(promptResult)

        -- If the condition is not met, print the error message and prompt the user again
        if not success then
            print(result)
            promptResult = stdio.prompt()
        else
            value = result
        end
    until success == true
    print()

    -- Update the last message type
    lastProgressLine = false

    return value
end

--[[
    Prints the process width
]]
CLIO.ShowProcessWidth = function(): ()
    printSpacing()
    print('The batch process table will be this wide:')
    print('<' .. string.rep("-", 165) .. '>')
    print("For the best experience, please expand the console window until the above appears on a single line.\n")
    lastProgressLine = false
end

--[[
    Prompts the user for confirmation
    @param prompt string - The confirmation message to display
]]
CLIO.PromptForConfirmation = function(prompt: string): ()
    printSpacing()
    stdio.prompt('text', "Press Enter to " .. prompt .. ", or Ctrl+C to cancel...")
    print()
    lastProgressLine = false
end

--[[
    Prints the current configurations
    @param sortOrder { string } - The order in which to display the configurations
    @param configs Types.ConfigValues - The configurations to print
]]
CLIO.PrintConfigs = function(sortOrder: { string }, configs: Types.ConfigValues): ()
    printSpacing()

    -- Print the configurations
    print("Current Configurations:")
    print("--------------------------")
    for _, key: string in ipairs(sortOrder) do
        if configs[key] ~= nil then
            print(string.format('%-25s', key) .. "|   " .. tostring(configs[key]))
        end
    end
    print()
    lastProgressLine = false
end

--[[
    Prints the progress line.
    @param processName string - The name of the process being monitored
    @param createTimestamp number - The timestamp when the process was created
    @param lastUpdateTimestamp number - The timestamp of the last update
    @param status string - The current status of the process (e.g. 'InProgress', 'Done', 'Failed')
    @param scannedItems number | string - Number of items that have been scanned
    @param processedItems number | string - Number of items that have been processed
    @param failedItems number - Number of items that failed processing
]]
CLIO.PrintProgressLine = function(
    processName: string, 
    createTimestamp: number, 
    lastUpdateTimestamp: number, 
    status: string, 
    scannedItems: number | string, 
    processedItems: number | string, 
    failedItems: number
): ()
    -- Generate the formatted timestamps
    local createTime = TimeUtil.FormatTimestamp(createTimestamp)
    local lastUpdateTime = TimeUtil.FormatTimestamp(lastUpdateTimestamp)
    if createTimestamp == 0 or lastUpdateTimestamp == 0 then
        createTime = "N/A"
        lastUpdateTime = "N/A"
    end

    -- Print the progress line
    stdio.write(TableUtil.FormatLine(
        processName,
        createTime,
        lastUpdateTime,
        status,
        scannedItems,
        processedItems,
        failedItems
    ))
    stdio.write('\r')

    lastProgressLine = true
end

--[[
    Prints the monitor mode progress header.
    @param processName string - The name of the process being monitored
    @param resume boolean - Whether the process is resuming from a previous state
]]
CLIO.PrintProgressHeader = function(processName: string, resume: boolean): ()
    printSpacing()

    print((resume and "Resuming" or "Starting") .. " process: " .. processName .. '\n')
    print(TableUtil.FormatLine(
        'Process Name',
        'Create Time',
        'Last Update Time',
        'Status',
        'Scanned',
        'Processed',
        'Failed'
    ))
    print(TableUtil.FormatSeparator(7))
    lastProgressLine = false
end

--[[
    Prints the list of batch processes.
    @param list { string } - The list of batch processes
]]
CLIO.PrintBatchProcessList = function(list: { string }): ()
    printSpacing()

    print('Batch Processes')
    print(TableUtil.FormatSeparator(1))
    for _, item: string in ipairs(list) do
        print(item)
    end
    print()
    lastProgressLine = false
end

--[[
    Prints the memory stores usage information.
    @param configs Types.ConfigValues - The configurations
]]
CLIO.PrintMemoryStoresUsageInformation = function(configs: Types.ConfigValues): ()
    printSpacing()
    print("Please note that this batch process will run against live Memory Stores. Please ensure you have enough quota to run this process without affecting your experience.\n\n"
    .. "\tThis batch process will use at most: " .. Formulas.CalculateMaxAccess(configs) .. " Request Units per minute and "
    .. math.min(configs.memoryStoresStorageLimit, Formulas.CalculateMaxStorage(configs)) .. " kb storage.\n\n"
    .. "\tIf you would like to change the storage limit, please use the --memory-stores-storage-limit option.\n"
    .. "\tThe allowable storage limit with these configurations is: [" .. Formulas.CalculateMinStorage(configs) .. ", " .. Formulas.CalculateMaxStorage(configs) .. "] kb.\n\n"
    .. "\tIf you would like to reduce the request rate, please tune your configurations according to the documentation.\n")
    lastProgressLine = false
end

--[[
    Prints a message directing the user to the CLI log file for debugging.
    @param processName string - The name of the process
    @param outputDirectory string - The output directory
]]
CLIO.PrintDirectionToCLILogFile = function(processName: string, outputDirectory: string): ()
    printSpacing()
    print("View the running CLI log file at " .. outputDirectory .. "/" .. processName .. "/cli.output for errors that may occur on the command line.\n")
    lastProgressLine = false
end

--[[
    Prints an error message and exits the program.
    @param message string - The error message
    @param callback Types.Function? - Optional callback function to execute before exiting
]]
CLIO.Error = function(message: string, callback: Types.Function?): ()
    printSpacing()
    lastProgressLine = false
    print("Error: " .. message .. "\n")
    if callback then
        callback()
    end
    process.exit(1)
end

--[[
    Prints a message to the CLI.
    @param message string? - The message to print
]]
CLIO.Print = function(message: string?): ()
    printSpacing()
    print((message or "") .. '\n')
    lastProgressLine = false
end

--[[
    Prints a completed message.
    @param processName string - The name of the process
    @param outputDirectory string - The output directory where logs are stored
]]
CLIO.Complete = function(processName: string, outputDirectory: string): ()
    printSpacing()
    print("Process " .. processName .. " completed successfully. Please review all failed items at " .. outputDirectory .. "/" .. processName .. "/failed_items.output.\n")
    lastProgressLine = false
end

--[[    
    Prints a failed message.
    @param processName string - The name of the process
    @param outputDirectory string - The output directory where logs are stored
]]
CLIO.Failed = function(processName: string, outputDirectory: string): ()
    printSpacing()
    print("Process " .. processName .. " failed. Please check the failed item logs at " .. outputDirectory .. "/" .. processName .. "/failed_items.output to diagnose the issue.\n")
    lastProgressLine = false
end

return CLIO
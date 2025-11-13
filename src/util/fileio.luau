--!strict

--[[
    File I/O utility functions.
]]

-- Native Libraries
local fs = require('@lune/fs')
local serde = require('@lune/serde')

-- Local Libraries
local Constants = require('../shared/constants')

-- File IO
local FileIO = {}

--[[
    Gets the directory from a filepath.
    @param filepath string - The full path to the file
    @return string - The directory of the file
]]
local function getDirectoryFromPath(filepath: string): string
    -- Replace backslashes with forward slashes for consistency
    filepath = string.gsub(filepath, "\\", "/")
    
    -- Find the last slash
    local lastSlash = string.find(filepath, "/[^/]*$")
    if not lastSlash then
        return ""
    end
    
    -- Return everything before the last slash
    return string.sub(filepath, 1, lastSlash - 1)
end

--[[
    Reads a file and returns the contents.
    @param filePath string - The path to the file to read
    @return string? - The contents of the file, or nil if the file does not exist
]]
FileIO.ReadFile = function(filePath: string): string?
    -- Read the file
    local success: boolean, file: string = pcall(fs.readFile, filePath)
    if not success then
        return nil
    end

    return file
end

--[[
    Reads a JSON file and returns the contents.
    @param filePath string - The path to the file to read
    @return {[string]: any}? - The contents of the file as a table, or nil if the file does not exist
]]
FileIO.ReadJsonFile = function(filePath: string): { [string]: any }?
    local file = FileIO.ReadFile(filePath)
    if not file then
        return nil
    end

    -- Try to decode the file
    local success, result = pcall(serde.decode, 'json', file)
    if not success then
        return nil
    end

    -- Return the decoded file as a table
    return result
end

--[[
    Reads a file by line.
    @param filepath string - The path to the file to read
    @return {string}? - A table of lines from the file or nil if the file does not exist
]]
FileIO.ReadFileByLine = function(filepath: string): { string }?
    local file = FileIO.ReadFile(filepath)
    if not file then
        return nil
    end

    -- Add each line to the table
    local lines = {}
    for line in file:gmatch("([^\n]*)\n?") do
        table.insert(lines, line)
    end

    return lines
end

--[[
    Writes a file.
    @param filepath string - The full path to the file
    @param contents string - The contents of the file
]]
FileIO.WriteFile = function(filepath: string, contents: string): ()
    local dir = getDirectoryFromPath(filepath)
    local success: boolean = pcall(fs.writeDir, dir)
    if not success then
        return
    end
    success = pcall(fs.writeFile, filepath, contents)
    if not success then
        return
    end
end

--[[
    Appends a line to a file.
    @param filepath string - The full path to the file
    @param line string - The line to append to the file
]]
FileIO.AppendLineToFile = function(filepath: string, line: string): ()
    local file = FileIO.ReadFile(filepath)
    if not file then
        return
    end

    -- Append the line to the file
    FileIO.WriteFile(filepath, file .. line .. "\n")
end

--[[
    Clears a file.
    @param filepath string - The full path to the file
]]
FileIO.ClearFile = function(filepath: string): ()
    local file = FileIO.ReadFile(filepath)
    if not file then
        return
    end

    -- Clear the file
    FileIO.WriteFile(filepath, "")
end

--[[
    Appends a line to the CLI log file.
    @param processName string - The name of the process
    @param outputDir string - The output directory
    @param line string - The line to append to the CLI log file
]]
FileIO.AppendToCLILogFile = function(processName: string, outputDir: string, line: string): ()
    FileIO.AppendLineToFile(outputDir .. "/" .. processName .. "/" .. Constants.CLILogFile, line)
end

--[[
    Removes the output files for a process.
    @param processName string - The name of the process
    @param outputDirectory string - The output directory
]]
FileIO.RemoveOutputFiles = function(processName: string, outputDirectory: string): ()
    pcall(function()
        fs.removeFile(outputDirectory .. "/" .. processName .. "/" .. Constants.CLILogFile)
    end)
    pcall(function()
        fs.removeFile(outputDirectory .. "/" .. processName .. "/" .. Constants.FailedItemsFile)
    end)
    pcall(function()
        fs.removeFile(outputDirectory .. "/" .. processName .. "/" .. Constants.BatchProcessFile)
    end)
    pcall(function()
        fs.removeFile(outputDirectory .. "/" .. processName .. "/" .. Constants.ActiveStage1TasksFile)
    end)
    pcall(function()
        fs.removeFile(outputDirectory .. "/" .. processName .. "/" .. Constants.ActiveStage2TasksFile)
    end)
    pcall(function()
        fs.removeFile(outputDirectory .. "/" .. processName .. "/" .. Constants.CompletedStage1TasksFile)
    end)
    pcall(function()
        fs.removeFile(outputDirectory .. "/" .. processName .. "/" .. Constants.CompletedStage2TasksFile)
    end)
end

--[[
    Creates the output files for a process.
    @param processName string - The name of the process
    @param outputDirectory string - The output directory
]]
FileIO.CreateOutputFiles = function(processName: string, outputDirectory: string): ()
    FileIO.WriteFile(outputDirectory .. "/" .. processName .. "/" .. Constants.CLILogFile, "")
    FileIO.WriteFile(outputDirectory .. "/" .. processName .. "/" .. Constants.FailedItemsFile, "")
    FileIO.WriteFile(outputDirectory .. "/" .. processName .. "/" .. Constants.BatchProcessFile, "")
    FileIO.WriteFile(outputDirectory .. "/" .. processName .. "/" .. Constants.ActiveStage1TasksFile, "")
    FileIO.WriteFile(outputDirectory .. "/" .. processName .. "/" .. Constants.ActiveStage2TasksFile, "")
    FileIO.WriteFile(outputDirectory .. "/" .. processName .. "/" .. Constants.CompletedStage1TasksFile, "")
    FileIO.WriteFile(outputDirectory .. "/" .. processName .. "/" .. Constants.CompletedStage2TasksFile, "")
end

return FileIO
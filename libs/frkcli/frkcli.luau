--!nolint LocalShadow

local process = require("@lune/process")

local M = {}

type ArgKind = "POSITIONAL" | "FLAG" | "OPTION"
type ArgOptions = {
    help: string?,
    aliases: { string }?,
    default: string?, -- if this is not nil, the arg will be optional
}

-- this is what is stored, we guarante non nullity when args are added so this types makes Luau feel better
type ArgOptionsSafe = {
    help: string,
    aliases: { string },
    default: string?,
}

type ArgData = {
    name: string,
    kind: ArgKind,
    options: ArgOptionsSafe,
}

type ParseResult = {
    values: { [string]: string },
    flags: { [string]: boolean },
    fwd_args: { string }, -- all args after `--`
}

type SubcommandParseResult = {
    command: string,
    result: ParseResult,
}

local DEFAULT_OPTIONS: ArgOptionsSafe = {
    help = "",
    default = nil,
    aliases = {},
}

local DEFAULT_helpset = {
    ["-h"] = true,
    ["--help"] = true,
}

local function validate_key_or_error(key: string)
    if (key:sub(1, 2) == "--" or key:sub(1, 1) == "-") and not key:find(" ") then
        return
    end
    error(`arg key {key} is invalid. Keys must start with either '-' or '--' and may not contain spaces`)
end

local function validate_subcommand_name_or_error(name: string)
    if name:sub(1, 2) == "--" or name:sub(1, 1) == "-" or name:find(" ") then
        error(`subcommand name '{name}' is invalid. Name must not start with '-' or '--' and may not contain spaces`)
    end
end

type HelpSection = { title: string, lines: { { string } | string }? }
local function make_help(sections: { HelpSection }, indent: number?): string
    local function align_cols(rows: { { string } }, sep: string?): { { string } }
        local sep = if sep == nil then " " else sep
        local max_col_lengths: { number } = {}
        for _, row in rows do
            for i, s in row do
                if max_col_lengths[i] == nil or s:len() > max_col_lengths[i] then
                    max_col_lengths[i] = s:len()
                end
            end
        end
        local aligned_rows: { { string } } = {}
        for _, row in rows do
            local line: { string } = {}
            for i, col in row do
                table.insert(line, col)
                if i < #row then
                    local spacing = sep
                    local diff = max_col_lengths[i] - col:len()
                    if diff > 0 then
                        spacing = string.rep(" ", diff) .. sep
                    end
                    table.insert(line, spacing)
                end
            end
            table.insert(aligned_rows, line)
        end
        return aligned_rows
    end

    local function append_list<T>(dest: { T }, src: { T })
        for _, v in src do
            table.insert(dest, v)
        end
    end

    local ind = "  "
    if indent ~= nil then
        ind = string.rep(" ", indent)
    end

    local help_lines: { { string } } = {}

    for _, s in sections do
        table.insert(help_lines, { s.title })
        if s.lines ~= nil then
            local section_lines: { { string } } = {}
            for _, l in s.lines do
                if typeof(l) == "string" then
                    table.insert(section_lines, { ind, l })
                else
                    table.insert(section_lines, { ind, table.unpack(l) })
                end
            end
            append_list(help_lines, align_cols(section_lines))
        end
        table.insert(help_lines, {})
    end

    -- remove last empty line
    table.remove(help_lines)

    local help_text = ""
    for _, line in help_lines do
        help_text ..= table.concat(line, " ") .. "\n"
    end
    return help_text
end
-- subcommand cli, must be first positional arg
function M.new_subcommands(name, description: string?, helpkeys: { string }?)
    -- args that trigger print help + abort
    local helpset: { [string]: boolean } = DEFAULT_helpset
    if helpkeys ~= nil then
        helpset = {}
        for _, k in helpkeys do
            helpset[k] = true
        end
    end

    local cli = {}
    cli.name = name
    cli.description = description
    cli._helpkeys = helpkeys
    cli._helpset = helpset
    cli._subcommands = {}

    function cli:add_subcommand(name: string, description: string?)
        validate_subcommand_name_or_error(name)
        local sc = M.new(name, description, cli._helpkeys)
        cli._subcommands[name] = sc
        return sc
    end

    function cli:parse(args_in: { string }): (SubcommandParseResult?, string?)
        local args = {}
        for _, v in args_in do
            table.insert(args, v)
        end
        if #args == 0 then
            return nil, "insufficient arguments, required at least 1, got 0"
        end
        local command = args[1]
        assert(command ~= nil)

        -- asking for help?
        if cli._helpset[command] ~= nil then
            print(cli:help())
            process.exit(0)
        end

        local subcommand = cli._subcommands[command]
        if subcommand == nil then
            return nil, `'{command} is not a valid subcommand`
        end

        local sub_args = { table.unpack(args, 2) }
        local res, err = subcommand:parse(sub_args)
        if err ~= nil then
            return nil, err
        end
        assert(res ~= nil)

        return {
            command = command,
            result = res,
        }, nil
    end

    function cli:help(indent: number?): string
        local help_sections: { HelpSection } = {}

        table.insert(help_sections, { title = `usage: {cli.name} <command>` })

        if cli.description ~= nil then
            table.insert(help_sections, {
                title = "description:",
                lines = { { cli.description } },
            })
        end

        local subcommand_lines = {}
        for _, c in cli._subcommands do
            local desc = if c.description then c.description else ""
            table.insert(subcommand_lines, { c.name, desc })
        end

        table.insert(help_sections, {
            title = "commands:",
            lines = subcommand_lines,
        })

        return make_help(help_sections, indent)
    end

    return cli
end

function M.new(name: string, description: string?, helpkeys: { string }?)
    -- args that trigger print help + abort
    local helpset: { [string]: boolean } = DEFAULT_helpset
    if helpkeys ~= nil then
        helpset = {}
        for _, k in helpkeys do
            helpset[k] = true
        end
    end

    -- I'm fairly certain this is not the right pattern for making objects, but it results in single definition + great LSP so I'm happy
    local cli = {}
    cli.name = name
    cli.description = description
    cli._helpset = helpset
    cli._positionals = {} :: { ArgData }
    cli._flags = {} :: { ArgData }
    cli._options = {} :: { ArgData }
    cli._argdata_set = {} :: { [string]: ArgData }
    cli._required_list = {} :: { string }
    cli._lookup = {} :: { [string]: ArgData }
    cli._required_positional_count = 0
    cli._default_result = { values = {}, flags = {} } :: ParseResult

    local function add_arg_lookups(keys: { string }, arg_data: ArgData)
        for _, k in keys do
            if cli._helpset[k] ~= nil then
                error(`key '{k}' is already used as a help key.`)
            end
            validate_key_or_error(k)
            if cli._lookup[k] ~= nil then
                error(`key '{k}' already exists.`)
            end
            cli._lookup[k] = arg_data
        end
    end

    local function add_name_error_on_duplicate(name: string, data: ArgData)
        if cli._argdata_set[name] ~= nil then
            error(`arg with name {name} already exists`)
        end
        cli._argdata_set[name] = data
    end

    local function make_safe_options(options: ArgOptions?): ArgOptionsSafe
        if options == nil then
            return DEFAULT_OPTIONS
        end
        assert(options)

        options.aliases = if options.aliases == nil then {} else options.aliases

        return options :: ArgOptionsSafe
    end

    -- return is guaranteed to start with at least one '-', if none, adds '--'
    local function to_lookup_name(name: string): string
        if name:sub(1, 1) == "-" then
            return name
        end
        return "--" .. name
    end

    -- return is guaranted to not start with '-'
    local function to_result_name(name: string): string
        while name:sub(1, 1) == "-" do
            name = name:sub(2, -1)
        end
        return name
    end

    function cli:add_positional(name: string, options: ArgOptions?)
        if name:sub(1, 1) == "-" then
            error(`invalid arg name '{name}', positional cannot start with dashes`)
        end

        local options = make_safe_options(options)

        local arg_data: ArgData = {
            name = name,
            kind = "POSITIONAL",
            options = options,
        }
        add_name_error_on_duplicate(name, arg_data)
        if options.default == nil then
            -- check positional required ordering, can't have a required pos after an optional one
            local last = cli._positionals[#cli._positionals]
            if last ~= nil and last.options.default ~= nil then
                error(
                    `{name} is required, but {last.name} is optional. Cannot have required positional after optional positional`
                )
            end

            table.insert(cli._required_list, name)
        else
            cli._default_result.values[name] = options.default
        end
        table.insert(cli._positionals, arg_data)
    end

    function cli:add_flag(name: string, options: ArgOptions?)
        if options and options.default ~= nil then
            -- these are called constants :)
            error(`flag {name} has non nil default, default value is not supported for flags`)
        end

        local options = make_safe_options(options)

        local lookup_name = to_lookup_name(name)
        name = to_result_name(name)
        for i, v in options.aliases do
            options.aliases[i] = to_lookup_name(v)
        end

        local arg_data: ArgData = {
            name = name,
            kind = "FLAG",
            options = options,
        }
        add_name_error_on_duplicate(name, arg_data)
        add_arg_lookups({ lookup_name, table.unpack(options.aliases) }, arg_data)

        if options.default ~= nil then
            error(`flag {name} has non nil default value, defaults are not supported for flag args`)
        end

        cli._default_result.flags[name] = false
        table.insert(cli._flags, arg_data)
    end

    function cli:add_option(name: string, options: ArgOptions?)
        local options = make_safe_options(options)

        local lookup_name = to_lookup_name(name)
        name = to_result_name(name)
        for i, v in options.aliases do
            options.aliases[i] = to_lookup_name(v)
        end

        local arg_data: ArgData = {
            name = name,
            kind = "OPTION",
            options = options,
        }
        add_name_error_on_duplicate(name, arg_data)
        add_arg_lookups({ lookup_name, table.unpack(options.aliases) }, arg_data)
        if options.default == nil then
            table.insert(cli._required_list, name)
        else
            if options.default == nil then
                error(`optional arg {name} must have a default value`)
            end
            assert(options.default ~= nil)
            cli._default_result.values[name] = options.default
        end
        table.insert(cli._options, arg_data)
    end

    -- return: data, err - where data is a table, and err is a string
    -- errors early, first encountered error ends the parse
    -- if a help key is found will print help text and exit the process
    function cli:parse(args_in: { string }): (ParseResult?, string?)
        local args = {}
        for _, v in args_in do
            table.insert(args, v)
        end
        local parsed: ParseResult = { values = {}, flags = {}, fwd_args = {} } :: ParseResult

        local positional_idx = 1
        local skip_next = false -- used for options
        for i, arg in args do
            -- asking for help?
            if cli._helpset[arg] ~= nil then
                print(cli:help())
                process.exit(0)
            end

            if skip_next then
                skip_next = false
                continue
            end

            -- rest of args should be fwd args
            if arg == "--" then
                parsed.fwd_args = { table.unpack(args, i + 1) }
                break
            end

            local has_dash = arg:sub(1, 1) == "-"
            local arg_data: ArgData? = nil
            local value: string? = nil

            if not has_dash then -- positional
                if positional_idx > #cli._positionals then
                    return nil, `too many positional arguments, expected {#cli._positionals}.`
                end
                arg_data = cli._positionals[positional_idx]
                positional_idx += 1
                value = arg
            else -- flag or option
                arg_data = cli._lookup[arg]
            end

            if arg_data == nil then
                return nil, `unknown flag or option: '{arg}'`
            end
            assert(arg_data ~= nil)

            -- handle flags early
            if arg_data.kind == "FLAG" then
                parsed.flags[arg_data.name] = true
                continue
            end

            -- get option value
            if arg_data.kind == "OPTION" then
                if i < #args then
                    value = args[i + 1]
                    skip_next = true
                end
            end

            -- resolve positionals and options
            if value == nil then
                return nil, `no value provided for option '{arg}'`
            end
            assert(value ~= nil)

            parsed.values[arg_data.name] = value
        end

        -- check all required options are provided
        for _, name in cli._required_list do
            if parsed.values[name] == nil and parsed.flags[name] == nil then
                local kind = cli._argdata_set[name].kind:lower()
                return nil, `required {kind} arg '{name}' was not found`
            end
        end

        -- apply defaults for missing optional
        for k, v in cli._default_result.flags do
            if parsed.flags[k] == nil then
                parsed.flags[k] = v
            end
        end
        for k, v in cli._default_result.values do
            if parsed.values[k] == nil then
                parsed.values[k] = v
            end
        end

        return parsed, nil
    end

    function cli:help(indent: number?): string
        local function align_cols(rows: { { string } }, sep: string?): { { string } }
            local sep = if sep == nil then " " else sep
            local max_col_lengths: { number } = {}
            for _, row in rows do
                for i, s in row do
                    if max_col_lengths[i] == nil or s:len() > max_col_lengths[i] then
                        max_col_lengths[i] = s:len()
                    end
                end
            end
            local aligned_rows: { { string } } = {}
            for _, row in rows do
                local line: { string } = {}
                for i, col in row do
                    table.insert(line, col)
                    if i < #row then
                        local spacing = sep
                        local diff = max_col_lengths[i] - col:len()
                        if diff > 0 then
                            spacing = string.rep(" ", diff) .. sep
                        end
                        table.insert(line, spacing)
                    end
                end
                table.insert(aligned_rows, line)
            end
            return aligned_rows
        end

        local help_sections: { HelpSection } = {}

        -- usage
        local usage = `usage: {cli.name}`
        if #cli._flags > 0 or #cli._options > 0 then
            usage ..= " [options]"
        end
        for _, arg in cli._positionals do
            if arg.options.default == nil then
                usage ..= ` <{arg.name}>`
            else
                usage ..= ` [{arg.name}]`
            end
        end

        table.insert(help_sections, { title = usage })

        -- description
        if cli.description ~= nil then
            table.insert(help_sections, { title = "description:", lines = { cli.description } })
        end

        local function make_arg_line(arg: ArgData): { string }
            local keys = arg.name
            if arg.kind ~= "POSITIONAL" then
                keys = `--{arg.name}`
                for _, a in arg.options.aliases do
                    keys ..= `, {a}`
                end
            end

            local reqdef = ""
            -- optional & default
            --[[
            if arg.kind ~= "FLAG" then
                if arg.options.default == nil then
                    reqdef ..= "[required]"
                else
                    assert(arg.options.default)
                    reqdef ..= `[default:  '{arg.options.default}']`
                end
            end
            ]]

            local help = ""
            if arg.options.help then
                if help ~= "" then
                    help ..= " "
                end
                help ..= arg.options.help
            end

            return { keys, reqdef, help }
        end

        -- positionals
        if #cli._positionals > 0 then
            local positional_lines: { { string } } = {}
            for _, arg in cli._positionals do
                table.insert(positional_lines, make_arg_line(arg))
            end
            table.insert(help_sections, { title = "positional arguments:", lines = positional_lines })
        end

        -- flags
        if #cli._flags > 0 then
            local flag_lines: { { string } } = {}
            for _, arg in cli._flags do
                table.insert(flag_lines, make_arg_line(arg))
            end
            table.insert(help_sections, { title = "flags:", lines = flag_lines })
        end

        -- options
        if #cli._options > 0 then
            local option_lines: { { string } } = {}
            for _, arg in cli._options do
                table.insert(option_lines, make_arg_line(arg))
            end
            table.insert(help_sections, { title = "options:", lines = option_lines })
        end

        return make_help(help_sections, indent)
    end

    return cli
end

export type Cli = typeof(M.new(""))
export type CliSubcommands = typeof(M.new_subcommands(""))

return M
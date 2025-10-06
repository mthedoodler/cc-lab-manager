---@diagnostic disable: param-type-mismatch
local expect = require "cc.expect"
local expect, field = expect.expect, expect.field

local logger = {}

logger.printFunctions = {}

local LOG_BUFFER = ""
    
local UTC = os.time(os.date("*t"))

local cwd = fs.getDir(shell.getRunningProgram())

local logWd = cwd .. "/logs"

if not fs.exists(logWd) then
    fs.makeDir(logWd)
end

local pastLogs = fs.find(logWd .. "/*.log")

if (#pastLogs >= 20) then
    table.sort(pastLogs)
    fs.delete(pastLogs[1])
end

logger.LOG_FILEPATH = logWd .. "/log" .. tostring(UTC) .. ".log"

logger.LOG = {}

logger.PRINT_DATE = false

local function getDate()
     return os.date("%Y-%m-%d %H:%M:%S")
end

function logger.quickLog()
    local f = fs.open(logger.LOG_FILEPATH, "r+")
    f.seek("end")
    f.write(LOG_BUFFER)
    f.close()
    LOG_BUFFER = ""
end

fs.open(logger.LOG_FILEPATH, "w").close()

function logger.makePrint(o)
    expect(1, o, "table")

    field(o, "prefix", "string")
    field(o, "flag", "string")
    field(o, "silent", "boolean")
    field(o, "foreground", "number", "nil")
    field(o, "background", "number", "nil")

    local function l(text, date)
        local date
        if not date then
            date = "[" .. getDate() .. "]"
         end

        LOG_BUFFER = LOG_BUFFER .. date .. " [" .. o.prefix .. "] " .. text .. "\n"
        logger.quickLog()
    end

    local function p(text)
        local date = "[" .. getDate() .. "]"

        if logger.DEBUG[o.flag] then

            local prefixText = "[" .. o.prefix .. "]"

            if logger.PRINT_DATE then
                prefixText = date .. " " .. prefixText
            end

            local textColor = term.getTextColor()
            local backgroundColor = term.getBackgroundColor()
            term.setTextColor(o.foreground or textColor)
            term.setBackgroundColor(o.background or backgroundColor)
            term.write(prefixText)
            term.setTextColor(textColor)
            term.setBackgroundColor(backgroundColor)
            term.write(" ")
            print(text)
        elseif (not o.silent or o.silent == nil) then
            print(text)
        end

        if logger.LOG[o.flag] then
            l(text, date)
        end
    end

    logger.printFunctions[o.flag] = {p, l}

    return p, l
end

return logger
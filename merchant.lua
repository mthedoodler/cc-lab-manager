--Run 'host.py' in Lab Manager venv.

local strings = require("cc.strings")
local expect = require("cc.expect")
local expect, field = expect.expect, expect.field

local mainframe = require("utils.mainframe")

local host = mainframe.host
local supplierNet = mainframe.supplierNet

local logger = mainframe.logger

local printFromMerchant = logger.printFromMerchant
local printFromHost = logger.printFromHost
local printFromSupplier = logger.printFromSupplier

local TIMEOUT = mainframe.TIMEOUT_SECONDS

-- ########################################################## --

SUPPLIERS = {}

local function generateCommandList(id)
    local supplier = SUPPLIERS[id]

    local commandList = "Supplier " .. tostring(id) .. " " .. supplier.name .. " has the following commands:"

    for cmd, _ in pairs(supplier.commands) do 
        commandList =  commandList .. "\n\t* " .. cmd
    end

    return commandList
end

local function registerSupplier(msg, id)
    if type(msg.name) == "string" and type(msg.type) == "string" and type(msg.commands) == "table" then
        printFromMerchant("Registering supplier " .. tostring(id))
        local supplier = {}

        supplier.commands = {}

        for _, cmd in pairs(msg.commands) do
            supplier.commands[cmd] = true
        end

        supplier.type = msg.type
        supplier.name = msg.name
        supplier.timeout = os.clock()

        SUPPLIERS[id] = supplier

        supplierNet.send(id, "ok", "register")
        printFromMerchant("Registered Supplier ".. msg.name .. "of type " .. msg.type)

        host.send(generateCommandList(id), "info")
    end
end

local function unregisterSupplier(id)
    printFromMerchant("Unregistering supplier " .. id .. " \"" .. SUPPLIERS[id].name .. "\"")
    supplierNet.send(id, "", "unregister")
    SUPPLIERS[id] = nil
end

local function parseArgs(argString)

    local args = {}
    local currentArg = ""

    local oldState = ""
    local state = "char" -- char / quote

    for i=1,argString:len() do
        local char = argString:sub(i, i)
        if state == "char" then
            if char == "\\" then
                oldState = state
                state = "escape"
            elseif char == "\"" then
                state = "quote"
            elseif char == " " then
                args[#args+1] = currentArg
                currentArg = ""
            else
                currentArg = currentArg .. char
            end
        elseif state == "quote" then
            if char == "\\" then
                oldState = state
                state = "escape"
            elseif char == "\"" then
                state = "char"
            else
                currentArg = currentArg .. char
            end
        elseif state == "escape" then
            currentArg = currentArg .. char
            state = oldState
        end
    end

    args[#args+1] = currentArg

    return args
end

local function getPCIDs()
    local computers = {peripheral.find("computer")}

    local peripheralTable = {}
    for _, pc in pairs(computers) do
        peripheralTable[pc.getID()] = pc
    end

    return peripheralTable
end

local PROTOCOL_HANDLERS = {
    info = {
        supplier = function(msg, id)
            host.send("<"..SUPPLIERS[id].name..":"..id..">: "..msg, "info")
        end,

        host = function(msg)
            host.send(msg, "info")
        end
    },

    echo = {
        supplier = function(msg, id)
            if type(msg) == "string" then
                msg = {message=msg}
            end

            if msg['return'] == true then
                printFromSupplier("<" .. id .. ":echo>" .. textutils.serialize(msg.message))
            else
                msg['return'] = true
                supplierNet.send(id, msg, "echo")
            end
        end,

        host = function(msg)
            if type(msg) == "string" then
                msg = {message=msg}
            end

            if msg['return'] == true then
                printFromHost("<echo>" .. textutils.serialize(msg.message))
            else
                msg['return'] = true
                host.send(msg, "echo")
            end
        end
    },

    register = {
        supplier = registerSupplier
    },

    unregister = {
        supplier = function(msg, id) unregisterSupplier(id) end
    },

    cmd = {
        host = function(msg) 

            local splitCmd = strings.split(msg, " ")

            local id = splitCmd[1]

            if id ~= "merchant" then
                id = tonumber(id)
            end

            local cmd = splitCmd[2]
            if id == nil then
                host.send("Invalid command.", "info")
            elseif id == "merchant" then
                host.send("WIP", "info")
            elseif SUPPLIERS[id] == nil then
                host.send("Supplier " .. id .. " does not exist.", "info")
            elseif cmd == "help" then
                host.send(generateCommandList(id), "info")
            elseif cmd == nil then
                host.send("No command given.", "info")
            elseif SUPPLIERS[id].commands[cmd] == nil then
                host.send("Supplier " .. id .. " does not support command " .. cmd .. ".", "info")
            else
                local argStart = splitCmd[1]:len() + splitCmd[2]:len() + 3
                local args = parseArgs(msg:sub(argStart))
                print(msg:sub(argStart))
                supplierNet.send(id, {cmd=cmd,
                                      args = args
                                      }, "cmd")
                msg = "Sending " .. cmd .. " to " .. SUPPLIERS[id].name .. " at " .. id
                host.send(msg, "info")
            end
        end
    },

    ping = {
        host = function(msg) 
            if msg == "ping" then
                host.send("pong", "ping")
            end
        end,

        supplier = function(msg, id)
            if msg == "ping" then
                supplierNet.send(id, "pong", "ping")
            end
        end
    },

    keepalive = {
        supplier = function(msg, id)
            if SUPPLIERS[id] then
                --printFromSupplier("Keepalive packet sent from " .. id)
                SUPPLIERS[id].timeout = os.clock()
            end
        end
    }
}

local function handleSuppliers()

    if type(host.websocket) ~= "table" then
        error("websocket not connected.")
    end

    while true do
        local id, msgId, message, protocol = supplierNet.receive()

        if message ~= nil then
            if protocol ~= "keepalive" then
                printFromSupplier("<" .. id .. ":" .. protocol .. ">: " .. textutils.serialise(message))
            end

            if PROTOCOL_HANDLERS[protocol] and PROTOCOL_HANDLERS[protocol].supplier then
                PROTOCOL_HANDLERS[protocol].supplier(message, id)
            end
        end
        sleep(0.05)
    end
end

local function handleHost()
    
    if type(host.websocket) ~= "table" then
        error("websocket not connected.")
    end

    while true do
        local _, message, protocol = host.receive()

        if message then
            printFromHost("<" .. protocol .. ">:" .. textutils.serialise(message))
            if PROTOCOL_HANDLERS[protocol] and PROTOCOL_HANDLERS[protocol].host then
                PROTOCOL_HANDLERS[protocol].host(message)
            else
                host.send("error", "protocol " .. protocol .. " not recognized.")
            end
        end
        sleep(0.05)
    end
end

local function handleTimeouts()
    while true do
        for id, info in pairs(SUPPLIERS) do
            if (os.clock() - info.timeout) >= (TIMEOUT+1) then
                printFromMerchant("Supplier " .. id .. " timed out.")
                host.send("Supplier " .. id .. " timed out.", "info")
                local supplierPeripheral = getPCIDs()[id]
                unregisterSupplier(id)

                if supplierPeripheral then
                    supplierPeripheral.turnOn()
                end
            else
                supplierNet.send(id, "", "keepalive")
            end
        end
        sleep(TIMEOUT)
    end
end

os.setComputerLabel("merchant") -- Sets PC's role

rednet.host("merchant", "merchant")
rednet.open(peripheral.getName(peripheral.find("modem")))

for id, computer in pairs(getPCIDs()) do
    computer.turnOn()
end

while true do
    host.connect()
    printFromMerchant("Connected!")
    local ok, res = pcall(function() parallel.waitForAny(handleHost, handleSuppliers, handleTimeouts) end)
    host.disconnect()
    
    for id, _ in pairs(SUPPLIERS) do
        unregisterSupplier(id)
    end

    if not ok then
        local disconnectErrPosition = {res:find("disconnect")}
        disconnectErrPosition = disconnectErrPosition[2]
        if (disconnectErrPosition) then
            printFromMerchant("Disconnected:" .. res:sub(disconnectErrPosition+2))
        else
            printFromMerchant("Disconnected due to crash: " .. res)
            break
        end
    end
end
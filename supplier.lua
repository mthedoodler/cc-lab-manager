local expect = require("cc.expect")
local expect, field = expect.expect, expect.field

local mainframe = require("utils.mainframe")

local supplierNet = mainframe.supplierNet

local logger = mainframe.logger

local printFromMerchant = logger.printFromMerchant
local printFromHost = logger.printFromHost
local printFromSupplier = logger.printFromSupplier

local merchantTimeout

local TIMEOUT_SECONDS = mainframe.TIMEOUT_SECONDS

local _rawSend = supplierNet.send
supplierNet.rawSend = _rawSend

function supplierNet.send(id, message, protocol, msgId)
    merchantTimeout = os.clock()
    supplierNet.rawSend(id, message, protocol, msgId)
end

local function findMerchant(timeout)
    local timeout = timeout or 1
    local merchantId
    repeat
        printFromSupplier("Searching for merchant...")
        merchantId = rednet.lookup("merchant", "merchant")
        if not merchantId then
            sleep(timeout)
        end

    until merchantId
    
    if type(merchantId) == "table" then
        merchantId = merchantId[1]
    end

    printFromSupplier("Found merchant at ID " .. merchantId)

    return merchantId
end

local function connectAndRegister(supplierInfo)

    local merchantId = findMerchant()

    printFromSupplier("Attempting to register supplier " .. supplierInfo.name)
    sleep(math.random(0, 200) / 20)

    supplierNet.rawSend(merchantId, supplierInfo, "register")
    while true do
        local ok, res = pcall(function() return {supplierNet.receive(10)} end)

        if ok then -- if message recieved in that time
        
            local id, msgId, msg, protocol = table.unpack(res)

            if protocol ~= "ack" then
                sleep(0.05)
                supplierNet.rawSend(merchantId, {
                    id = msgId,
                    from = protocol
                }, "ack")

                if (protocol == "register") and (msg ~= nil) and (id == merchantId) then
                    if msg.type == "ok" then
                        printFromMerchant("Sucessfully registered!")
                        break
                    end
                end
            end --use original to prevent timeouting
        end
        
        printFromSupplier("Retrying...")
        supplierNet.rawSend(merchantId, supplierInfo, "register")
    end

    return merchantId
end

local function supply(merchantId, commands, protocolHandlers)
    
    local ctx = {
        merchantId = merchantId,
        log = printFromSupplier,
        sendToMerchant = function(msg, protocol)
            expect(1, msg, "table", "string")
            expect(2, protocol, "string")
            supplierNet.send(merchantId, protocol)
        end
    }

    local function _run()
        printFromSupplier("Ready for commands!")
        while true do
            local id, msgId, message, protocol = supplierNet.receive()

            if message ~= nil then
                if protocol ~= "ack" then
                    printFromMerchant("<" .. protocol .. ">" .. textutils.serialise(message))
                end

                if id == merchantId then
                    supplierNet.rawSend(merchantId, {
                            id = msgId,
                            from = protocol
                    }, "ack")
                    
                    if protocol == "ack" then
                        merchantTimeout = nil
                    elseif protocol == "reregister" then
                        printFromSupplier("Request to reregister received(did the merchant reboot?)")
                        return
                    elseif protocol == "cmd" then
                        printFromSupplier("Command package recieved: " ..textutils.serialise(message))
                        if message.type == "request" then
                            local command = message.command
                            if type(command) == "table" then 
                                if commands[command.cmd] then
                                    local ok, res = pcall(function() commands[command.cmd](command.args, ctx) end)
                                    
                                    local returnMsg = {
                                            type="response",
                                            id = msgId,
                                            command = command,
                                        }
                                    
                                    if ok then
                                        returnMsg.status = "ok"
                                        returnMsg.results = res or {}
                                    else
                                        returnMsg.status = "error"
                                        print(type(res))
                                        if type(res) == "table" then
                                            returnMsg.error = res
                                        else
                                            returnMsg.error = {type="lua-error", msg=tostring(res)}
                                        end
                                    end

                                    printFromSupplier(textutils.serialise(returnMsg))
                                    
                                    sleep(0.05)
                                    supplierNet.send(merchantId, returnMsg, "cmd")
                                else
                                    printFromSupplier("Invalid command recieved: " .. textutils.serialise(command))
                                end
                            end
                        end
                    elseif protocol == "unregister" then
                        printFromSupplier("Request to unregister received. Unregistering.")
                        return
                    elseif protocol == "ping" then
                        supplierNet.send(merchantId, "pong", "ping")
                    elseif protocolHandlers[protocol] then
                        protocolHandlers[protocol](merchantId, printFromSupplier)
                    else
                        supplierNet.send(merchantId, "unrecognized protocol", "error")
                    end
                end
            end
        end
    end

    local function _keepAlive()
        while true do
            sleep(TIMEOUT_SECONDS)
            if (merchantTimeout) and (os.clock() - merchantTimeout) >= (TIMEOUT_SECONDS+1) then
                printFromSupplier("Merchant timed out. Unregistering.")
                return
            end
        end
    end

    parallel.waitForAny(_run, _keepAlive)
end

-- Register this computer as a supplier and begin recieving commands. Best called in parallel.waitForAny().waitForAll
-- name: unique name of this supplier.
-- type: the type of supplier. Used to determine the icon.
-- commands: a table of commands that this supplier can accept. the keys are the command's name, and the values are functions to be ran when they are called.

local supplier = {}

function supplier.register(name, type, commands, protocolHandlers)
    expect(1, name, "string")
    expect(2, type, "string")
    expect(3, commands, "table")
    expect(4, protocolHandlers, "table", "nil")

    local protocolHandlers = protocolHandlers or {}

    local modems = {peripheral.find("modem")}

    for _, modem in pairs(modems) do
        rednet.open(peripheral.getName(modem))
    end

    local COMMAND_NAMES = {}

    for cmd, _ in pairs(commands) do
        table.insert(COMMAND_NAMES, cmd)
    end

    local supplierInfo = {
        name = name,
        type = type,
        commands = COMMAND_NAMES
    }

    print(textutils.serialise(COMMAND_NAMES))
    while true do
        local ok, res = pcall(function() 
            local merchantId = connectAndRegister(supplierInfo)
            supply(merchantId, commands,protocolHandlers) end)
        merchantTimeout = nil
        printFromSupplier("Disconnected from Merchant.")
        if not ok then
            local disconnectErrPosition = {res:find("disconnect")}
            disconnectErrPosition = disconnectErrPosition[2]
            if (disconnectErrPosition) then
                printFromSupplier("Disconnect reason:" .. res:sub(disconnectErrPosition+2) .. ":" .. res)
            else
                printFromSupplier("Fatal crash: " .. res)
                break
            end
        end
    end
end

return supplier

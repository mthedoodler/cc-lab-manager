local logger = require("utils.logger")
local expect = require("cc.expect")
local expect, field = expect.expect, expect.field

local printFromSupplier = logger.makePrint({
    flag = "SUPPLIER",
    foreground=colors.yellow,
    prefix = "SUPPLIER",
    silent = true
})

local printFromHost = logger.makePrint({
    flag = "HOST",
    foreground=colors.lightBlue,
    prefix = "HOST",
    silent = true
})

local printFromMerchant = logger.makePrint({
    flag = "MERCHANT",
    foreground=colors.orange,
    prefix = "MERCHANT",
    silent = true
})

logger.DEBUG = {HOST=true, SUPPLIER=true, MERCHANT=true}
logger.LOG = logger.DEBUG

local url = "ws://localhost:8001"

local LAB_PROTOCOL = "lab"

local host = {}

local function generateMessageID()
    return ("%d-%d-%d"):format(os.getComputerID(), os.epoch("utc"), math.random(0, 9999))
end

local function isValidPacket(packet)
    return (type(packet) == "table") and (type(packet.msg == "string") or type(packet.msg) == "table") and (type(packet.protocol) == "string") and (type(packet.id) == "string") end

local function decodeMessage(msg)
    expect(1, msg, "string")

    local res, err = textutils.unserialiseJSON(msg)

    if not res then
        return nil, "invalid json"
    end

    if not isValidPacket(res) then
       return nil, "json missing protocol, message, or id field"
    end

    return {id=res.id, message=res.message, protocol=res.protocol}
end

local function encodeMessage(msgId, message, protocol)
    expect(1, message, "string", "table")
    expect(2, protocol, "string")

    return textutils.serialiseJSON({
            message = message,
            protocol = protocol,
            id = msgId
        })
end

local supplierNet = {}

function supplierNet.send(id, message, protocol)
    local packetID = generateMessageID()
    rednet.send(id, encodeMessage(packetID, message, protocol), LAB_PROTOCOL)
end

function supplierNet.receive(timeout)
    local id, packet, _ = rednet.receive(LAB_PROTOCOL, timeout)

    if packet == nil then
        error("disconnect: no packet received")    
    end

    local msg, err = decodeMessage(packet)

    if err then
        supplierNet.send(id, err, "error")
        return nil
    end

    return id, msg.id, msg.message, msg.protocol
end

function host.send(message, protocol)
    host.websocket.send(encodeMessage("", message, protocol))
end

function host.receive()
    local ok, res = pcall(host.websocket.receive)
    if not ok then
        error("disconnect: closed websocket")
    end

    local packet = res 

    if packet == nil then
        error("disconnect: empty packet")
    end
    
    local msg, err = decodeMessage(packet)

    if err then
        host.websocket.send(encodeMessage("", "error", err))
        return nil
    end

    return msg.id, msg.message, msg.protocol
end

function host.connect(timeout)
    expect(1, timeout, "number", "nil")

    timeout = timeout or 5

    local ws

    printFromMerchant("Trying to connect to host")

    repeat
        ws = http.websocket(url)
        if not ws then 
            printFromMerchant("Failure to connect. Retrying...")
            sleep(timeout)
        end
    until ws

    host.websocket = ws
end

function host.disconnect()
    host.websocket.close()
    host.websocket = nil

    local _, isCoroutine = coroutine.running()
    if isCoroutine then
        error("disconnect", 2)
    end
end

return {host=host, 
        supplierNet=supplierNet, 
        logger={printFromHost=printFromHost, printFromMerchant=printFromMerchant, printFromSupplier=printFromSupplier},
        TIMEOUT_SECONDS = 10
    }
-- TODO this better with a background process that keeps net info

local component = require("component")
local serialization = require("serialization")
local event = require("event")

local net = {}
local printMessages = true

local ROUTER_RESP_TTL = 3

local modem = nil
for a, _ in pairs(component.list("modem")) do
    modem = component.proxy(a)
    break
end
if modem == nil then
    print("A network card is required.")
    return
end
local modemPort = 67
modem.open(modemPort)

local computerData = {
    networkAddr = modem.address,
    ip = nil,
    gatewayAddr = nil,
    gatewayIp = nil,
    subnetMask = nil -- TODO implement
}

local callback = nil


local function rprint(...)
    if not printMessages then return end
    local n = select("#",...)
    io.write("[WANAPI]")
    for i = 1,n do
        local v = tostring(select(i,...))
        io.write(v)
        if i~=n then io.write'\t' end
    end
end
local function print(...)
    if not printMessages then return end
    rprint(...)
    io.write("\n")
end


function net.load(c, doPrintDebug) -- load the lib, provide a callback to read incoming messages
    callback = c
    if doPrintDebug ~= nil then
        printMessages = doPrintDebug
    end
    local payload = serialization.serialize({
        HEADER = {
            SA = computerData.networkAddr
            --DA = @everyone
        },
        body = {
            title = "DHCPDISCOVER"
        }
    })
    modem.broadcast(modemPort, payload)
end

function net.getNetworkCardData()
    return {
        ip = computerData.ip,
        gateway = computerData.gatewayIp,
        subnet = computerData.subnetMask,
        addr = computerData.networkAddr,
    }
end

function net.getRouterInfo()
    local payload = {
        title = "ROUTERINFO"
    }

    local function eventFilter(name, ...)
        if name ~= "modem_message" then
            return false
        end
        local sdata = select(5, ...)
        local data = serialization.unserialize(sdata)

        if data.HEADER and data.HEADER.DA == computerData.ip then
            if data.body and data.body.title == "ROUTERINFORESP" then
                return true
            end
        end
        
        return false
    end

    print("Sending request to router and waiting for response")
    net.sendMessage(computerData.gatewayIp, payload)
    local _, _, _, _, _, sdata = event.pullFiltered(ROUTER_RESP_TTL, eventFilter)
    
    if sdata == nil then return nil end

    return serialization.unserialize(sdata).body.info
end

function net.getARPTable()
    local payload = {
        title = "ARPGET"
    }

    local function eventFilter(name, ...)
        print("[ARP filter]", ...)
        if name ~= "modem_message" then
            return false
        end
        local sdata = select(5, ...)
        local data = serialization.unserialize(sdata)

        if data.HEADER and data.HEADER.DA == computerData.ip then
            if data.body and data.body.title == "ARPRESP" then
                return true
            end
        end
        
        return false
    end

    print("Sending request to router and waiting for response")
    net.sendMessage(computerData.gatewayIp, payload)
    local _, _, _, _, _, sdata = event.pullFiltered(ROUTER_RESP_TTL, eventFilter)
    
    if sdata == nil then return nil end

    return serialization.unserialize(sdata).body.ARP
end

function net.debug()
    for i, j in pairs(computerData) do print(i, j) end
end

function net.sendMessage(ip, body)
    if not computerData.ip or not computerData.gatewayAddr then
        print("lib not initialized correctly, ip was not assigned to this pc. did you load()?")
    end

    local payload = serialization.serialize({
        HEADER = {
            SA = computerData.ip,
            DA = ip
        },
        body = body
    })

    print("DEBUG", "modem_send ".. computerData.gatewayAddr, modemPort, payload)
    modem.send(computerData.gatewayAddr, modemPort, payload)
end

local function modemReceive(_, localAddr, senderAddr, port, _, sdata)
    local data = serialization.unserialize(sdata)
    if data.HEADER then
        if data.HEADER.DADDR and (data.HEADER.DADDR ~= computerData.networkAddr) then
            return -- Dest Addr was not this pc, so definitely discard message  
        end
        if (computerData.ip and data.HEADER.DA) and (data.HEADER.DA ~= computerData.ip) then
            return -- Dest IP was not this pc, definitely discard message
        end
    else
        -- data was sent with no HEADER, maybe it's from an unrelated script?
        print("Received data with no header, discarding")
        return
    end

    if data.HEADER.SA == nil then -- since HEADER will only be used on print, cast nil to string to avoid errors on concatenation
        data.HEADER.SA = "nil"
    end
    if data.HEADER.DA == nil then
        data.HEADER.DA = "nil"
    end
    if data.HEADER.DADDR == nil then
        data.HEADER.DADDR = "nil"
    end

    -- if both HEADER.DA and HEADER.DADDR are nil then the message was broadcasted to everyone.

    print("ACCEPTED MSG", "FROM " .. data.HEADER.SA, "TO " .. data.HEADER.DA..":"..data.HEADER.DADDR, "TITLE ", data.body.title)

    local body = data.body

    if body and body.title then
        if body.title == "DHCPOFFER" then -- save DHCP data
            computerData.ip = body.ip
            computerData.gatewayIp = body.gateway.ip
            computerData.gatewayAddr = body.gateway.address

            print("ACK DHCP", "IP " .. computerData.ip, "FROM " .. computerData.gatewayIp .. " " .. computerData.gatewayAddr)
            
            if callback then callback("Assigned IP: " .. computerData.ip) end
            return
        elseif body.title == "MESSAGE" then
            if callback and body.message then
                print("ACK MSG", "FROM " .. data.HEADER.SA, "TO " .. data.HEADER.DA)
                callback(body.message)
            else
                print("Received message but there was no callback")
            end
            return
        elseif body.title == "STRING" then
            if callback and body.message then
                print("ACK STRING", "FROM " .. data.HEADER.SA, "TO " .. data.HEADER.DA)
                callback(body.message)
            else
                print("Received message but there was no callback")
            end
        else
            return -- don't handle data with other TITLES (may be directed to routers or other)
        end
    end
end

local function modem_message_callback(...)
    local success, err = pcall(modemReceive, ...)
    -- print errors
    if not success then
        print("Error in callback:", err)
    end
end
event.listen("modem_message", modem_message_callback)


local function program_interrupted()
    event.ignore("modem_message", modem_message_callback)
    event.ignore("interrupted", program_interrupted)
end
event.listen("interrupted", program_interrupted)


return net
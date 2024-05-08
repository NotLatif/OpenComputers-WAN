-- Central node that allows communications between Routers over the WAN
local os = require("os")
local thread = require("thread")
local event = require("event")
local component = require("component")
local serialization = require("serialization")

local modem = component.modem

local ispData = {
    ip = "100.0.0.0",
    reqPort = 69, --ISP will receive requests on port 69
    respPort = 68 --ISP will respond on port 68
}

local ARP = {}

modem.open(ispData.reqPort)
modem.open(ispData.respPort)


local function saveEntryToARP(addr, ip)
    ARP[addr] = ip
end

local function getIPFromAddr(addr)
    if ARP[addr] ~= nil then
        return ARP[addr]
    end
    return nil
end

local function getAddrFromIP(ip)
    local addr = nil
    for a, i in pairs(ARP) do
        if i == ip then
            return a
        end
    end
    return nil
end

local function generateNewIp(address, reassign)
    if reassign then
        local x = getIPFromAddr(address)
        if x ~= nil then
            print("Reassigning IP")
            return x -- return IP already in ARP table
        end
    end

    local ip = nil

    while ip == nil do
        local o1 = tostring(math.floor(math.random(11, 255)))
        local o2 = tostring(math.floor(math.random(0, 255)))
        local o3 = tostring(math.floor(math.random(0, 255)))
        local o4 = tostring(math.floor(math.random(0, 255)))

        ip = o1 .. "." .. o2 .. "." .. o3 .. "." .. o4
        if getAddrFromIP(ip) ~= nil then
            ip = nil
        else
            print("Generatred new ip", ip)
        end
    end
    return ip
end


local function modemSend(ip, data)
    local daddr = getAddrFromIP(ip)

    local payload = serialization.serialize({
        HEADER = {
            SA = modem.address,
            DA = ip,
            DADDR = daddr            
        },
        body = data
    })

    modem.send(daddr, ispData.respPort, payload)
end

local function modemBroadcast(data)
    local payload = serialization.serialize(data)
    modem.broadcast(ispData.respPort, payload)
end

local function modemForward(ip, data)
    local daddr = getAddrFromIP(ip)

    local payload = serialization.serialize(data)
    print("Forwarding message to " .. daddr, payload)
    modem.send(daddr, ispData.respPort, payload)
end

local function modemReceive(_, thisaddr, saddr, port, _, sdata)
    local data = serialization.unserialize(sdata)
    -- print("modem_message", da, sa, port, sdata)
    
    -- TODO huh??
    -- if port ~= ispData.respPort and port ~= ispData.respPort then
    --     return
    -- end

    local senderIP = nil
    if data.HEADER and data.HEADER.SA then
        senderIP = data.HEADER.SA
    end
    
    print("RECEIVED MESSAGE FROM ["..senderIP.."]("..saddr..")", port)
    print(sdata)
    
    if data.HEADER and data.HEADER.DA ~= ispData.ip then
        if data.body and data.body.title ~= "DHCPDISCOVER" then
            -- destination is not the ISP, trying to forward data
            modemForward(data.HEADER.DA, data)
        end
    end

    if data.body.title == "DHCPDISCOVER" then
        local assignedIP = generateNewIp(saddr, true)

        local payload = serialization.serialize({
            HEADER = {
                SA = ispData.ip,
                DADDR = saddr,
            }, body = {
                title = "DHCPOFFER",
                ip = assignedIP,
                ispIP = ispData.ip
            }
        })

        saveEntryToARP(saddr, assignedIP) -- TODO listen for response and saveEntryToARP then (full DHCP protocol)

        modem.send(saddr, ispData.respPort, payload)

    elseif data.body.title == "ACK_INIT" then
        if data.HEADER.SA then
            print("Detected router [".. data.HEADER.SA .."]", saddr)
            saveEntryToARP(saddr, data.HEADER.SA)
        end
        
    elseif data.body.title == "GETARP" then -- discorver connected routers
    elseif data.body.title == "GETDOMAINS" then -- discover "public" domains
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

local function syncronizeExistingRouters()
    print("isp modem address: " .. modem.address)
    -- find active routers
    local payload = {
        HEADER = {SA = ispData.ip},
        body = {
            title = "SYN_INIT",
            ip = ispData.ip
        }
    }
    print("Broadcasting router discovery")
    modemBroadcast(payload)
end
syncronizeExistingRouters()


while true do
---@diagnostic disable-next-line: undefined-field
    os.sleep()
end
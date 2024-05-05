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
            return addr
        end
    end
    return nil
end

local function generateNewIp(address)
    local ip = nil

    while ip == nil do
        local o1 = tostring(math.floor(math.random(0, 255)))
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

local function modemForward(ip, serializedData)
    local daddr = getAddrFromIP(ip)
    local data = serialization.unserialize(serializedData)
    print("Forwarded message", data.HEADER.SA, data.HEADER.DA, data.body.title)
    modem.send(daddr, ispData.respPort, serializedData)
end

local function modemReceive(_, da, sa, port, _, sdata)
    print("modem_message", da, sa, port, sdata)
    if port ~= ispData.reqPort then
        return
    end
    print("RECEIVED MESSAGE", da, sa, port)
    print(sdata)

    local data = serialization.unserialize(sdata)
    if data.body.title == "DHCPDISCOVER" then
        local assignedIP = generateNewIp(sa)

        local payload = serialization.serialize({
            HEADER = {
                SA = ispData.ip,
                DADDR = sa,
            }, body = {
                title = "DHCPOFFER",
                ip = assignedIP
            }
        })

        saveEntryToARP(sa, assignedIP) -- TODO listen for response and saveEntryToARP then (full DHCP protocol)

        modem.send(sa, ispData.respPort, payload)
    
    elseif data.body.title == "MESSAGE" then
        modemForward(data.HEADER.DA, sdata)
    end
end

event.listen("modem_message", modemReceive)

while true do
---@diagnostic disable-next-line: undefined-field
    os.sleep()
end
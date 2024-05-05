local os = require("os")
local event = require("event")
local component = require("component")
local serialization = require("serialization")

local ISP_DISCOVERY_TTL = 2

local local_modem_port = 67
local remote_modem_port = 68
local isp_port = 69

local routerData = {
    ispAddr = nil,
    ip = "10.0.0.0",
    public_ip = nil,
}

local modem = {
    lan = nil,
    wan = nil
}

local ARP = {
    i = 0
    -- addr = "ip"
}



local function saveEntryToARP(addr, ip)
    ARP[addr] = ip
end

local function isIpInLan(ip)
    --checks ip against subnet mask to determine if it's in LAN
    
    -- since subnet is not yet implemented we'll simplify this
    if string.find(ip, "10.0.0") == nil then
        return false
    else
        return true
    end
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

local function generateLocalIp(addr, reassign)
    if reassign then
        local x = getIPFromAddr(addr)
        if x ~= nil then
            print("Reassigning IP")
            return x -- return IP already in ARP table
        end
    end

    local ip = "10.0.0."
    ARP.i = ARP.i + 1
    ip = ip .. tostring(ARP.i)
    
    if getAddrFromIP(ip) == nil then
        print("Gave new IP")
        return ip
    else
        return generateLocalIp(addr, reassign)
    end
end


local function modemForward(data)
    if (not data.HEADER.DA) and (not data.HEADER.DADDR) then
        print("message to forward had not destination, dropped.")
    end

    local payload = serialization.serialize(data)
    
    if data.HEADER.DADDR then
        local D_IP = getIPFromAddr(data.HEADER.ADDR)
        if D_IP ~= nil then 
            -- destination addr is in LAN
            modem.lan.send(data.HEADER.DADDR, payload)
        else
            -- DADDR is not in LAN, skip
        end
    end

    if data.HEADER.DA then
        local D_ADDR = getAddrFromIP(data.HEADER.DA)
        if D_ADDR ~= nil then
            -- destination ip is in NAT table (so it's in LAN)
            print("forwarding to LAN address", D_ADDR .. " ->")
            modem.lan.send(D_ADDR, local_modem_port, payload)
        elseif not isIpInLan(data.HEADER.DA) then
            -- destination in is WAN
            if routerData.ispAddr then
                print("forwarding to WAN ip", data.HEADER.DA .. " -->")
                modem.wan.send(routerData.ispAddr, remote_modem_port, payload)
            end
        else
            print("Couldn't find destination. dropped")
            -- destination is in LAN range but not in NAT, drop
            -- TODO broadcast to find if there is a pc with this ip? maybe not...
        end
    end
end

local function modemSend(ip, data)

    local payload = serialization.serialize({
        HEADER = {
            SA = routerData.ip,
            DA = ip
        },
        body = data
    })
    
    local addr = getAddrFromIP(ip)

    if isIpInLan(ip) then
        if addr == nil then
            print("Data sent WAN broadcast [ip] -->")
            modem.wan.broadcast(isp_port, payload)
        else
            print("Data sent WAN addr [ip] -->")
            modem.wan.send(addr, isp_port, payload)
        end
    else
        if addr == nil then
            print("Data sent LAN broadcast [ip] ->")
            modem.lan.broadcast(local_modem_port, payload)
        else
            print("Data sent LAN addr [ip] ->")
            modem.lan.send(addr, local_modem_port, payload)
        end
    end
end

local function modemSendAddr(addr, data)
    local destIP = getIPFromAddr(addr)

    local payload = serialization.serialize({
        HEADER = {
            SA = routerData.ip,
            DA = destIP,
            DADDR = addr
        },
        body = data
    })

    if destIP == nil then -- we don't know if recipient is local or remote
        print("DADDR not found, LAN|WAN broadcast [addr] =>")
        modem.wan.send(addr, isp_port, payload)
        modem.lan.send(addr, local_modem_port, payload)
        return
    end

    if string.find(destIP, "10.0.0") == nil then -- only send to network where recipient is
        print("Data sent WAN addr [addr] ->")
        modem.wan.send(addr, isp_port, payload)
    else
        print("Data sent LAN addr [addr] ->")
        modem.lan.send(addr, local_modem_port, payload)
    end
end

local function routerHandleLAN(senderAddr, data)
    print(serialization.serialize(data))
    local body = data.body

    if data.HEADER.DA and data.HEADER.DA ~= routerData.ip then
        -- data was not for this router, forward it to DA
        modemForward(data)
        return
    end

    if data.HEADER.DADDR and data.HEADER.DADDR ~= routerData.address then
        -- data was not for this router Address, forward it but still process it after
        modemForward(data)
    end

    -- data was for this router
    if body and body.title then
        print("ACK " .. body.title, "FROM " .. data.HEADER.SA)

        if body.title == "DHCPDISCOVER" then
            
            local assignedIP = generateLocalIp(senderAddr, true)

            local payload = {
                title = "DHCPOFFER",
                ip = assignedIP,
                gateway = {
                    ip = routerData.ip,
                    address = modem.lan.address
                }
            }
            print("DHCPOFFER", "to ".. senderAddr, "IP ".. assignedIP)
            -- save IP to table
            saveEntryToARP(senderAddr, assignedIP)
            -- send data to address (not to ip since computer does not have it yet)
            modemSendAddr(senderAddr, payload)

        elseif body.title == "ROUTERINFO" then
            print("asked INFO")
            local payload = {
                title = "ROUTERINFORESP",
                info = {
                    ip = routerData.ip,
                    addr = routerData.address,
                    public_ip = routerData.public_ip,
                    isp_addr = routerData.ispAddr
                }
            }

            modemSend(data.HEADER.SA, payload)

        elseif body.title == "ARPGET" then
            print("asked ARP")
            local payload = {
                title = "ARPRESP",
                ARP = ARP
            }

            modemSend(data.HEADER.SA, payload)
        end
    end
end

local function routerHandleWAN(senderAddr, data)
    -- figure out to which LAN computer to send
    -- forward to LAN
end

local function modemReceive(_, localAddr, senderAddr, port, _, sdata)
    local data = serialization.unserialize(sdata)
    if (port ~= local_modem_port) and (port ~= remote_modem_port) then
        return -- only handle messages coming throu port local_modem_port and remote_modem_port
    end

    if localAddr == modem.lan.address then
        print("-> RECEIVED LAN", "FROM " .. data.HEADER.SA .. ":" .. senderAddr, "PORT " .. port)
        routerHandleLAN(senderAddr, data)
    elseif localAddr == modem.wan.address then
        print("-> RECEIVED WAN", "FROM " .. data.HEADER.SA, "PORT " .. port)
        routerHandleWAN(senderAddr, data)
    else
        print("ERROR", "received message on uninitialized network card")
    end
end

local function init()
    -- initializes network cards to distinguish them
    local modems = {}
    for a, _ in pairs(component.list("modem")) do
        table.insert(modems, a)
    end

    if #modems ~= 2 then
        print("You need TWO network cards and one needs to be connected to your ISP, the other to your LAN network.")
        return
    end

    local function eventFilter(name, ...)
        if name ~= "modem_message" then
            return false
        end
        local sdata = select(5, ...)
        local data = serialization.unserialize(sdata)

        for _, a in pairs(modems) do
            if data.HEADER and data.HEADER.DADDR == a then
                if data.body and data.body.title == "DHCPOFFER" then
                    return true
                end
            end
        end
        
        return false
    end

    print("Searching ISP (may take up to " .. ISP_DISCOVERY_TTL*2 .. " seconds)")
    local ISPFound = false

    -- TODO multithread this?
    for _, a in pairs(modems) do
        local m = component.proxy(a)

        if ISPFound then
            print("Found internal modem", m.address)
            modem.lan = m
            break
        end

        local payload = serialization.serialize({
            HEADER = {
                SA = m.address,
            },
            body = {
                title = "DHCPDISCOVER"
            }
        })

        m.open(isp_port)
        m.open(remote_modem_port)

        m.broadcast(isp_port, payload)
        local _, _, sa, _, _, sdata = event.pullFiltered(ISP_DISCOVERY_TTL, eventFilter)
        
        m.close(isp_port)
        m.close(remote_modem_port)
        
        if sdata then
            local data = serialization.unserialize(sdata)
            ISPFound = true
            modem.wan = m

            routerData.public_ip = data.body.ip
            routerData.ispAddr = sa
            print("Found external modem", m.address)
        else
            print("Found internal modem", m.address)
            modem.lan = m
        end
    end

    if not ISPFound then
        modem.lan = nil
        modem.wan = nil
        print("ISP not found, retrying in 10 seconds...")
        os.sleep(10)
        init()
    else
        print("opening LAN and WAN ports")
        modem.lan.open(local_modem_port)
        modem.wan.open(remote_modem_port)
        modem.wan.open(isp_port)

        print("IP addr: ", routerData.public_ip)
    end

    print("-- INIT DONE --")
end

init()

event.listen("modem_message", function(...)
    local success, err = pcall(modemReceive, ...)
    -- print errors
    if not success then
        print("Error in callback:", err)
    end
end)

while true do
---@diagnostic disable-next-line: undefined-field
    os.sleep()
end
local os = require("os")
local event = require("event")
local component = require("component")
local serialization = require("serialization")

local ISP_DISCOVERY_TTL = 2 -- 2 real seconds
local CLEANUP_TIMER = 60 * 5 -- 5 real minutes (set to 0 to never cleanup)
local NAT_TTL = 720 * 6 * 4 -- (minecraft seconds) -> 4 real minutes

-- 720 MCs = 10 IRLsec -> 720*6 MCs = 1IRLmin

local local_modem_port = 67
local remote_modem_port = 68
local isp_port = 69

local routerData = {
    isp = {
        ip = nil,
        addr = nil
    },
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

local NAT = {}


local function extractFirstAddressPart(address)
    return address:match("([^-]+)")
end

local function extractFourthOctet(ipAddress)
    local octets = {}
    for octet in string.gmatch(ipAddress, "%d+") do
        table.insert(octets, tonumber(octet))
    end
    return octets[4]
end

local function saveNATEntry(localAddr, destIP)
    if localAddr == nil or destIP == nil then
        return nil
    end

    local NATEntry = destIP .. ":" .. extractFirstAddressPart(localAddr)
    NAT[NATEntry] = {
        address = localAddr,
        TTL = os.time() + NAT_TTL
    }
    return NATEntry
end

local function refreshNATEntry(entry)
    NAT[entry].TTL = os.time() + NAT_TTL
end

local function matchNATEntryToAddr(sourceIP, ephemeralPort) -- sourceIP is the one from WAN
    if sourceIP == nil or ephemeralPort == nil then
        return nil
    end

    local NATEntry = sourceIP .. ":" .. ephemeralPort
    local destAddr = NAT[NATEntry].address
    if destAddr then
        refreshNATEntry(NATEntry)
        return destAddr
    else
        print("NAT entry not found (probably expired).")
        return nil
    end
end

local function cleanup()
    for k, v in pairs(NAT) do
        if v.TTL > os.time() then
            NAT[k] = nil
        end
    end
end


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

local function getARP_IPFromAddr(match_addr)
    if ARP[match_addr] ~= nil then
        return ARP[match_addr]
    end
    return nil
end

local function getARP_AddrFromIP(match_ip)
    local addr = nil
    for a, ip in pairs(ARP) do
        if ip == match_ip then
            return a
        end
    end
    return nil
end

local function generateLocalIp(addr, reassign)
    if reassign then
        local x = getARP_IPFromAddr(addr)
        if x ~= nil then
            print("Reassigning IP")
            return x -- return IP already in ARP table
        end
    end

    local ip = "10.0.0."
    ARP.i = ARP.i + 1
    ip = ip .. tostring(ARP.i)

    if getARP_AddrFromIP(ip) == nil then
        print("Generated new IP")
        return ip
    else
        return generateLocalIp(addr, reassign)
    end
end


local function lanForward(addr, ip, unserializedData) -- forward to lan without altering packet
    local payload = serialization.serialize(unserializedData)
    if addr == nil then
        print("ERROR asked to forward to lan without providing addr. dropping")
        return
    end
    if ip == nil then
        ip = "nil"
    end
    print("forwarding to LAN address " .. addr .. " [" .. ip .. "]" .. " ->")
    modem.lan.send(addr, local_modem_port, payload)
end

local function wanForward(ip, unserializedData) -- forward to wan without altering packet
    local payload = serialization.serialize(unserializedData)
    if ip == nil then
        ip = "N/A" -- ip may be nil, if it's absent in serializedData the ISP will drop the packet
    end
    print("forwarding to WAN ip [" .. ip .. "]" .. " -->")
    modem.wan.send(routerData.isp.addr, remote_modem_port, payload)
end

local function lanBroadcast(unserializedData)
    print("Data broadcasted to LAN ->>")
    modem.lan.broadcast(local_modem_port, serialization.serialize(unserializedData))
end
local function wanBroadcast(unserializedData)
    print("Data broadcasted to WAN -->>")
    modem.wan.broadcast(remote_modem_port, serialization.serialize(unserializedData))
end

local function modemForward(data) -- forwards lan/wan messages not meant to the router
    if (not data.HEADER.DA) and (not data.HEADER.DADDR) then
        print("message to forward had not destination, dropped.")
    end

    if data.HEADER.DADDR then -- should not trigger unless the lib was modified or a custom packet was crafted
        print("WARNING - router received a LAN packet with an ADDRESS destination, this should not happen normally, report unless intentional.")
        if data.HEADER.DA then
            if isIpInLan(data.HEADER.DA) then
                if data.HEADER.DA ~= getARP_IPFromAddr(data.HEADER.DADDR) then
                    print("WARNING - an addr and an IP was provided but they don't match the ARP table, forwarding to ADDR (keeping IP in header)")
                    -- data.HEADER.DA = nil
                    lanForward(data.HEADER.DADDR, nil, data)
                else
                    lanForward(data.HEADER.DADDR, data.HEADER.DA, data)
                end
                return
            else
                -- DA point to WAN, forward to WAN
                print("an ADDR was provided with a public IP, discarding ADDR")
                data.HEADER.DADDR = nil
                wanForward(data.HEADER.DA, data)
                return
            end
        else
            -- only ADDR was provided, usually the recipient should be the router but whatever, forward to LAN
            local dest_ip = getARP_IPFromAddr(data.HEADER.ADDR)
            if dest_ip == nil then
                print("No matching IP was found on ARP table, since this is probably a custom crafted packet, forwarding to ADDR")
            else
                data.HEADER.DA = dest_ip
            end
            lanForward(data.HEADER.DADDR, dest_ip, data) -- dest_ip may be nil, lanSend handles this
            return
        end

    else -- if DADDR = nil then DA must not be nil
        if isIpInLan(data.HEADER.DA) then
            -- destination is in LAN, check against ARP table and forward
            local D_ADDR = getARP_AddrFromIP(data.HEADER.DA)
            if D_ADDR ~= nil then
                -- found destination IP in ARP table
                lanForward(D_ADDR, data.HEADER.DA, data)
            else
                print("Couldn't find LAN destination in ARP table. dropped")
                -- TODO broadcast to find if there is a pc with this ip? maybe not...
            end
        else
            -- destination in is WAN
            if routerData.isp.addr then
                wanForward(data.HEADER.DA, data)
            else
                print("ISP not initialized, dropped packet with public ip destination")
            end
        end
    end
end

local function routerCraftPacketAndSendToIP(ip, data) --sends packets generated by the router
    print("Crafting packet and sending to ip", ip)
    local payload = {
        HEADER = {
            SA = routerData.ip,
            DA = ip
        },
        body = data
    }

    if isIpInLan(ip) then
        local addr = getARP_AddrFromIP(ip)
        if addr == nil then
            print("Could not find addr in ARP table, broadcasting message")
            lanBroadcast(payload)
        else
            lanForward(addr, ip, payload)
        end
    else -- this should not trigger as router will only talk to WAN through IP when forwarding
        wanForward(ip, payload)
    end
end

local function routerCraftPacketAndSendToAddr(addr, data) --sends packets generated by the router
    print("Crafting packet and sending to addr", addr)
    local destIP = getARP_IPFromAddr(addr)
    local payload = {
        HEADER = {
            SA = routerData.ip,
            DA = destIP,
            DADDR = addr
        },
        body = data
    }

    if addr == routerData.isp.addr then -- message for ISP (only possible wan addr)
        if destIP ~= nil then
            print("WARNING - ISP addr was found in ARP table ??? removing entry")
            ARP[addr] = nil
        end
        print("Sending packet to ISP -->")
        modem.wan.send(routerData.isp.addr, remote_modem_port, serialization.serialize(payload))
        return
    end

    if destIP == nil then
        print("Couldn't find destination IP, forwarding to LAN.")
        lanForward(addr, nil, payload)
    elseif isIpInLan(destIP) then -- local IP in ARP
        lanForward(addr, destIP, payload)
    else
        print("WARNING - a public IP [" ..destIP .. "] was found in ARP table ??? removing entry, dropping packet")
        ARP[addr] = nil
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
        -- data was not for this router Address, forward it (this should not trigger normally)
        -- OCs should talk in LAN and to WAN only through IP addresses, but whatever.
        modemForward(data)
        return
    end

    -- data was from LAN and for this router
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
            routerCraftPacketAndSendToAddr(senderAddr, payload)

        elseif body.title == "ROUTERINFO" then
            print("asked INFO")
            local payload = {
                title = "ROUTERINFORESP",
                info = {
                    ip = routerData.ip,
                    addr = routerData.address,
                    public_ip = routerData.public_ip,
                    isp_addr = routerData.isp.addr,
                    isp_ip = routerData.isp.ip
                }
            }
            routerCraftPacketAndSendToIP(data.HEADER.SA, payload)

        elseif body.title == "ARPGET" then
            print("asked ARP")
            local payload = {
                title = "ARPRESP",
                ARP = ARP
            }
            routerCraftPacketAndSendToIP(data.HEADER.SA, payload)
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
            routerData.isp.ip = data.body.ispIP
            routerData.isp.addr = sa
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

    print("ISP: ", "addr: "..routerData.isp.addr, "ip: "..routerData.isp.ip)

    print("-- INIT DONE --")
end

init()

local function modem_message_callback(...)
    local success, err = pcall(modemReceive, ...)
    -- print errors
    if not success then
        print("Error in callback:", err)
    end
end

event.listen("modem_message", modem_message_callback)

local cleanupTimerID = nil
if CLEANUP_TIMER > 0 then
    event.timer(CLEANUP_TIMER, cleanup, math.huge)
end

local function program_interrupted()
    event.ignore("modem_message", modem_message_callback)
    event.ignore("interrupted", program_interrupted)

    if cleanupTimerID then
        event.cancel(cleanupTimerID)
    end
end
event.listen("interrupted", program_interrupted)

while true do
---@diagnostic disable-next-line: undefined-field
    os.sleep()
end
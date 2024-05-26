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
    isp = { -- isp data table
        ip = nil, -- public_ip of the ISP
        addr = nil -- network address fo the ISP
    },
    ip = "10.0.0.0", -- LAN ip address (gateway)
    public_ip = nil, -- public ip address
    subnet_mask = "255.255.255.0"
}

local modem = {
    lan = nil, -- modem component proxy facing LAN
    wan = nil -- modem component proxy facing WAN
}

local ARP = { i = 0 } -- addr = "localip"

local PortMappingTable = {} -- "port" = "local ip"

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

local function isNatAssigned(localPort, localIp)
    local NATEntry = localIp .. ":" .. localPort
    if NAT[NATEntry] then
        return true
    end
    return false
end

local function saveNATEntry(localIP, remoteIP, remotePort) -- returns assigned port
    if localIP == nil or remoteIP == nil or remotePort == nil then
        return nil
    end

    local localPort = tostring(math.floor(math.random(49152, 65535)))
    while isNatAssigned(localPort, localIP) do
        localPort = tostring(math.floor(math.random(49152, 65535)))
    end

    local NATEntry = localIP .. ":" .. localPort

    NAT[NATEntry] = {
        localIP = localIP,
        remoteIP = remoteIP,
        remotePort = remotePort,
        localPort = localPort,
        TTL = os.time() + NAT_TTL
    }
    return localPort
end

local function refreshNATEntry(entry)
    NAT[entry].TTL = os.time() + NAT_TTL
end

local function getNATLocalIP(remoteIP, localPort) -- sourceIP is the one from WAN
    if remoteIP == nil or localPort == nil then
        return nil
    end

    for k, v in pairs(NAT) do
        if v.localPort == localPort then
            if v.remoteIP == remoteIP then
                refreshNATEntry(k)
                return v.localIP, v.remotePort, k
            end
        end
    end

    print("NAT entry not found (probably expired).")
    return nil, nil, nil
end

local function getNATEntry(remoteIP, localPort)
    local _, _, e = getNATLocalIP(remoteIP, localPort)
    if e == nil then    return nil    end
    return NAT[e]
end

local function saveEntryToMappingTable(port, ip)
    if port == nil or ip == nil then
        print("no port or ip provided", port, ip)
        return false, "ARG_ERROR"
    end
    if PortMappingTable[port] then
        if PortMappingTable[port] == ip then
            print("port was already mapped to that ip")
            return true, "NO_CHANGE"
        else
            print("port was mapped to another ip")
            return false, "ALREADY_USED"
        end
    else
        PortMappingTable[port] = ip
        return true, "SUCCESS"
    end
end

local function getMappingTableEntry(port) -- may return nil
    return PortMappingTable[port]
end

local function getMappingTableEntriesForIP(ip)
    local mappings = {}
    for p, i in pairs(PortMappingTable) do
        if i == ip then
            mappings[p] = i
        end
    end
    return mappings
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
    if modem.lan == nil then
        print("LAN moem not initialized, could not forward msg.")
        return
    end

    if addr == nil then
        local arpAddr = getARP_AddrFromIP(ip)
        if arpAddr then
            addr = arpAddr
        else
            print("ERROR could not find destination address, dropping.")
            return
        end
    end
    if ip == nil then
        local arpIP = getARP_IPFromAddr(addr)
        if arpIP then
            ip = arpIP
        else
            ip = "nil"
        end
    end

    local payload = serialization.serialize(unserializedData)
    print("forwarding data:", payload)
    print("forwarding to LAN address " .. addr .. " [" .. ip .. "]" .. " ->")
    
    modem.lan.send(addr, local_modem_port, payload)
end
local function lanBroadcast(unserializedData)
    if modem.lan == nil then
        print("LAN moem not initialized, could not broadcast msg.")
        return
    end
    print("Data broadcasted to LAN ->>")
    modem.lan.broadcast(local_modem_port, serialization.serialize(unserializedData))
end

local function wanForward(ip, unserializedData) -- forward to wan without altering packet
    if modem.wan == nil then
        print("WAN moem not initialized, could not forward msg.")
        return
    end
    if ip == routerData.isp.ip and unserializedData.HEADER.SA == routerData.ip then -- message is from router to ISP, don't process it, just send it
        local payload = serialization.serialize(unserializedData)
        modem.wan.send(routerData.isp.addr, remote_modem_port, payload)
        return
    end
    
    if ip == nil then
        if unserializedData.HEADER.DA then
            ip = unserializedData.HEADER.DA
        else
            -- probably the router is talking to the ISP directly, otherwise the ISP will drop the packet
            ip = "nil"
        end
    end

    -- save to NAT
    if unserializedData.HEADER.DA and unserializedData.HEADER.SA and unserializedData.HEADER.DP then
        local localPort = saveNATEntry(unserializedData.HEADER.SA, unserializedData.HEADER.DA, unserializedData.HEADER.DP)
        unserializedData.HEADER.SP = localPort
        print("Opened local port for responses: " .. localPort)
        -- send ephemeral port open info to sender OC in LAN
        local lanPayload = {
            HEADER = {
                SA = routerData.ip,
                DA = unserializedData.HEADER.SA
            },
            body = {
                title = "EPORTFWD",
                port = localPort
            }
        }
        lanForward(nil, unserializedData.HEADER.SA, lanPayload)
    else
        print("Data for NAT missing, message responses won't be forwarded")
    end

    local payload = serialization.serialize(unserializedData)
    print("forwarding data:", payload)
    print("forwarding to WAN ip [" .. ip .. "]" .. " -->")
    modem.wan.send(routerData.isp.addr, remote_modem_port, payload)
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
            if data.HEADER.DP == nil then
                print("Forwarding message to WAN without port -->")
            end
            if routerData.isp.addr then
                wanForward(data.HEADER.DA, data)
            else
                print("ISP not initialized, dropped packet with public ip destination")
            end
        end
    end
end

local function routerCraftPacketAndSendToIP(ip, unserializedBody, uuid) --sends packets generated by the router
    print("Crafting packet and sending to ip", ip, uuid)
    local payload = {
        HEADER = {
            SA = routerData.ip,
            DA = ip,
            uuid = uuid
        },
        body = unserializedBody
    }

    if isIpInLan(ip) then
        local addr = getARP_AddrFromIP(ip)
        if addr == nil then
            print("Could not find addr in ARP table, broadcasting message")
            lanBroadcast(payload)
        else
            lanForward(addr, ip, payload)
        end
    else
        wanForward(ip, payload)
    end
end

local function routerCraftPacketAndSendToAddr(addr, data, uuid) --sends packets generated by the router
    if modem.wan == nil then
        print("WAN moem not initialized, could not forward msg to addr.")
        return
    end
    print("Crafting packet and sending to addr", addr)
    local destIP = getARP_IPFromAddr(addr)
    local payload = {
        HEADER = {
            SA = routerData.ip,
            DA = destIP,
            DADDR = addr,
            uuid = uuid
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


local function handleNCC(unserializedData)
    -- context: message OC in LAN
    local body = unserializedData.body

    if body and body.req then
        if body.req.title == "PMR" then
            if body.req.external_port then
                print("Port Mapping Request", unserializedData.HEADER.uuid)
                local s, msg = saveEntryToMappingTable(body.req.external_port, unserializedData.HEADER.SA)

                if s then
                    print(msg .. "  new mapping entry: " .. unserializedData.HEADER.SA .. ":" .. body.req.external_port)
                    body = {
                        title = "PMA", -- ACK
                        port = body.req.external_port
                    }
                else
                    print("Error", msg)
                    body = {
                        title = "PMF", -- failure
                        err = msg
                    }
                end
                routerCraftPacketAndSendToIP(unserializedData.HEADER.SA, body, unserializedData.HEADER.uuid)
                return
            end
        end
    end

    print("got an empty NCC request, dropping.", body)
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
                isp = routerData.isp.ip,
                gateway = {
                    ip = routerData.ip,
                    address = modem.lan.address,
                    subnet_mask = routerData.subnet_mask,
                    public_ip = routerData.public_ip
                }
            }
            print("DHCPOFFER", "to ".. senderAddr, "IP ".. assignedIP)
            -- save IP to table
            saveEntryToARP(senderAddr, assignedIP)
            -- send data to address (not to ip since computer does not have it yet)
            routerCraftPacketAndSendToAddr(senderAddr, payload)

        elseif body.title == "ACK_INIT" then
            if data.HEADER.SA == nil or data.HEADER.SA == "nil" then
                local assignedIP = generateLocalIp(senderAddr, true)

                local payload = {
                    title = "DHCPOFFER",
                    ip = assignedIP,
                    gateway = {
                        ip = routerData.ip,
                        address = modem.lan.address,
                        subnet_mask = routerData.subnet_mask,
                        public_ip = routerData.public_ip
                    }
                }
                print("DHCPOFFER", "to ".. senderAddr, "IP ".. assignedIP)
                -- save IP to table
                saveEntryToARP(senderAddr, assignedIP)
                -- send data to address (not to ip since computer does not have it yet)
                routerCraftPacketAndSendToAddr(senderAddr, payload)
                return
            else
                print("Detected lan computer ["..data.HEADER.SA.."]")
                saveEntryToARP(senderAddr, data.HEADER.SA)
                return
            end
        end

        -- request types subsequent to this line require a sender ip address
        if data.HEADER.SA == nil then
            print("Dropping packet without sender address")
            return
        end

        print("LAN REQ uuid: ", data.HEADER.uuid)

        if body.title == "GET-ROUTERINFO" then
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
            routerCraftPacketAndSendToIP(data.HEADER.SA, payload, data.HEADER.uuid)

        elseif body.title == "ARPGET" then
            print("asked ARP")
            local payload = {
                title = "ARPRESP",
                ARP = ARP
            }
            routerCraftPacketAndSendToIP(data.HEADER.SA, payload, data.HEADER.uuid)

        elseif body.title == "NATGET" then
            print("asked NAT")
            local payload = {
                title = "NATRESP",
                NAT = NAT,
                NAT_TTL = NAT_TTL
            }
            routerCraftPacketAndSendToIP(data.HEADER.SA, payload, data.HEADER.uuid)

        elseif body.title == "PMTGET" then
            local PMT = nil
            if body.ip then
                PMT = getMappingTableEntriesForIP(body.ip)
            else
                PMT = PortMappingTable
            end
            local payload = {
                title = "PMTRESP",
                PMT = PortMappingTable
            }
            routerCraftPacketAndSendToIP(data.HEADER.SA, payload, data.HEADER.uuid)

        elseif body.title == "NCC" then -- Network Configuration Command
            print("received network configuration command")
            handleNCC(data)
            
        end
    end
end

local function routerHandleWAN(data)
    if data then
        if data.HEADER then
            if data.HEADER.DA == nil then
                -- isp sent message to every router
                if data.body then
                    if data.body.title and data.body.title == "SYN_INIT" then
                        if data.body.ip and data.body.ip ~= routerData.isp.ip then
                            routerData.isp.ip = data.body.ip
                        end

                        local payload = {
                            HEADER = {
                                SA = routerData.public_ip,
                                DA = routerData.isp.ip,
                                DADDR = routerData.isp.addr
                            },
                            body = {
                                title = "ACK_INIT", -- all needed data is in header
                            }
                        }
                        wanForward(routerData.isp.ip, payload)
                    end
                end

                return
            end
            if data.HEADER.DA ~= routerData.ip then
                print("wrong recipient, processing anyways")
            end
            if data.HEADER.DP then
                -- packet is for LAN
                -- check against port mapping table
                local lanDestinationForwardedIp = getMappingTableEntry(data.HEADER.DP)
                local lanDestinationNATIp = getNATEntry(data.HEADER.SA, data.HEADER.DP)
            
                if lanDestinationForwardedIp ~= nil and lanDestinationNATIp ~= nil then
                    -- debug?
                    print("Found destination on both mapping table and NAT table??\nMAP: " .. lanDestinationForwardedIp, "NAT: " .. lanDestinationNATIp.localIP)
                    print(data)
                end

                if lanDestinationForwardedIp then
                    -- destination found in Mapping table
                    print("Forwarding WAN message to [" .. lanDestinationForwardedIp .. "]")
                    lanForward(nil, lanDestinationForwardedIp, data)
                end

                if lanDestinationNATIp then
                    -- destination found in NAT table
                    print("Forwarding WAN message to [" .. lanDestinationNATIp.localIP .. "]")
                    lanForward(nil, lanDestinationNATIp.localIP, data)
                end
            
            else
                -- packet is for this router
            end
        else
            print("got packet with no header from wan?? dropping")
            return
        end
    else
        print("got empty packet from wan??? dropping")
        return
    end
    -- figure out to which LAN computer to send
    -- forward to LAN
end

local function modemReceive(_, localAddr, senderAddr, port, _, sdata)
    if (port ~= local_modem_port) and (port ~= remote_modem_port) then
        return -- only handle messages coming throu port local_modem_port and remote_modem_port
    end

    local data = serialization.unserialize(sdata)
    if data.HEADER == nil then
        print("Dropping packet with no header")
        return
    end

    if data.HEADER.SA == nil then data.HEADER.SA = "nil" end

    if modem.lan and localAddr == modem.lan.address then
        print("-> RECEIVED LAN", "FROM " .. data.HEADER.SA .. ":" .. senderAddr, "PORT " .. port, data.HEADER.uuid)
        routerHandleLAN(senderAddr, data)
    elseif modem.wan and localAddr == modem.wan.address then
        print("-> RECEIVED WAN", "FROM " .. data.HEADER.SA, "PORT " .. port)
        routerHandleWAN(data)
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
        os.exit()
    end

    local function eventFilter(name, ...)
        if name ~= "modem_message" then
            return false
        end
        local sdata = select(5, ...)
        local data = serialization.unserialize(sdata)

        for _, a in pairs(modems) do
            if data.HEADER and data.HEADER.DADDR == a then
                if data.body and (data.body.title == "DHCPOFFER" or data.body.title == "ACK_LAN") then
                    return true
                end
            end
        end
        
        return false
    end

    print("Searching (may take up to " .. ISP_DISCOVERY_TTL*2 .. " seconds)")

    local function fetch()
        -- TODO multithread this?
        for i, a in pairs(modems) do
            local m = component.proxy(a)

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

                if data.body.title == "DHCPOFFER" then
                    modem.wan = m

                    routerData.public_ip = data.body.ip
                    routerData.isp.ip = data.body.ispIP
                    routerData.isp.addr = sa
                    print("Found external modem", m.address)

                    if i == 1 then
                        modem.lan = component.proxy(modems[2])
                        if modem.lan then
                            print("Found internal modem", modem.lan.address)
                        else
                            print("ERR, modem proxy was nil [2]")
                        end
                    else
                        modem.lan = component.proxy(modems[1])
                        if modem.lan then
                            print("Found internal modem", modem.lan.address)
                        else
                            print("ERR, modem proxy was nil [1]")
                        end
                    end

                elseif data.body.title == "ACK_INIT" then
                    print("Found internal modem", m.address)
                    modem.lan = m
                end
            else
                print("No response")
            end
        end

        if modem.wan == nil then
            if modem.lan ~= nil then
                print("BUG? modem.lan was found but modem.wan is nil")
            else
                modem.lan = nil
                modem.wan = nil
                print("Retrying in 10 seconds.")
                os.sleep(10)
                fetch()
                return
            end
        else
            if modem.lan == nil then
                print("BUG? modem.wan was found but modem.lan is nil")
            else
                print("Router initialized succesfully")
            end
        end
    end

    fetch()

    print("opening LAN and WAN ports")

    modem.lan.open(local_modem_port)
    modem.wan.open(remote_modem_port)
    modem.wan.open(isp_port)
    print("IP addr: ", routerData.public_ip)

    print("ISP: ", "addr: "..routerData.isp.addr, "ip: "..routerData.isp.ip)

    print("-- INIT DONE --")
end

local function cleanup()
    for p, v in pairs(NAT) do
        if v.TTL > os.time() then
            local payload = {
                title = "EPORTCLOSE",
                port = v.localPort
            }
            print("Deleting expired NAT entry: ["..v.localIP..":"..v.localPort.."]")
            routerCraftPacketAndSendToIP(v.localIP, payload)
            
            NAT[p] = nil
        end
    end
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


local function syncronizeExistingLAN()
    -- find active opencomputers
    local payload = {
        HEADER = {SA = routerData.ip},
        body = {
            title = "SYN_INIT",
            gateway = routerData.ip
        }
    }
    print("broadcasting LAN for online computers")
    lanBroadcast(payload)
end
syncronizeExistingLAN()

while true do
---@diagnostic disable-next-line: undefined-field
    os.sleep()
end
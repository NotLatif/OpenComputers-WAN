-- TODO this better with a background process that keeps net info

local component = require("component")
local serialization = require("serialization")
local event = require("event")

local net = {}
local printMessages = true

local ROUTER_RESP_TTL = 3
local ROUTER_RESP_LONG_TTL = 10

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
    publicIp = nil,
    subnetMask = nil -- TODO implement
}

local callback = nil
local forwardedPorts = {}
local ephemeralPorts = {}

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

local function dummy(...) end

function net.load(c, doPrintDebug) -- load the lib, provide a callback to read incoming messages from both LAN and WAN
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

function net.isForwardedPort(port)
    if forwardedPorts[port] then
        return true
    end
    return false
end

local function editForwardedPort(port, c) -- needs router ACK
    if c == nil then
        forwardedPorts[port] = dummy
    else
        forwardedPorts[port] = c
    end
end

local function removeForwardedPort(port) -- needs router ACK
    forwardedPorts[port] = nil
end

function net.isEphemeralPort(port)
    if ephemeralPorts[port] then
        return true
    end
    return false
end

local function addEphemeraPort(port) -- needs router ACK
    ephemeralPorts[port] = port
end

local function removeEphemeraPort(port) -- needs router ACK
    ephemeralPorts[port] = nil
end

function net.getNetworkCardData()
    return {
        ip = computerData.ip, -- the lan ip of this OC
        gateway = computerData.gatewayIp, -- the lan ip of the router
        subnet = computerData.subnetMask, -- the subnet mask
        addr = computerData.networkAddr, -- the address of this OC's network card
        public_ip = computerData.publicIP -- the public ip of the LAN router
    }
end

function net.askDomainName(domain)
    local payload = {
        title = "DNS_POST",
        name = domain
    }

    local function eventFilter(name, ...)
        if name ~= "modem_message" then
            return false
        end
        local sdata = select(5, ...)
        local data = serialization.unserialize(sdata)

        if data.HEADER and data.HEADER.DA == computerData.ip then
            if data.body and (data.body.title == "DNS_ACK" or data.body.title == "DNS_DENY") then
                return true
            end
        end
        return false
    end

    print("Sending request to router and waiting for response")
    net.sendMessage(computerData.gatewayIp, payload)
    local _, _, _, _, _, sdata = event.pullFiltered(ROUTER_RESP_TTL, eventFilter)

    if sdata == nil then return nil, "did not respond" end
    local data = serialization.unserialize(sdata).body

    if data.response == "DNS_DENY" then
        return nil, data.reason
    else
        return data.response, data.reason
    end
end

function net.addSubdomain(domain, subdomain)
    local payload = {
        title = "DNS_PUT",
        domain = domain,
        subdomain = subdomain
    }

    local function eventFilter(name, ...)
        if name ~= "modem_message" then
            return false
        end
        local sdata = select(5, ...)
        local data = serialization.unserialize(sdata)

        if data.HEADER and data.HEADER.DA == computerData.ip then
            if data.body and (data.body.title == "DNS_ACK" or data.body.title == "DNS_DENY") then
                return true
            end
        end
        return false
    end

    print("Sending request to router and waiting for response")
    net.sendMessage(computerData.gatewayIp, payload)
    local _, _, _, _, _, sdata = event.pullFiltered(ROUTER_RESP_TTL, eventFilter)

    if sdata == nil then return nil, "did not respond" end
    local data = serialization.unserialize(sdata).body

    if data.response == "DNS_DENY" then
        return nil, data.reason
    else
        return data.response, data.reason
    end
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

function net.requestPortMapping(port, callbackFunc)
    local payload = {
        title = "NCC",
        req = {
            title = "PMR",
            external_port = port
        }
    }

    local function eventFilter(name, ...)
        if name ~= "modem_message" then
            return false
        end
        local sdata = select(5, ...)
        local data = serialization.unserialize(sdata)
        print("FILTER - ", sdata)
        if data.HEADER and data.HEADER.DA == computerData.ip then
            if data.body and (data.body.title == "PMA" or data.body.title == "PMF") then
                return true
            end
        end
        return false
    end

    print("Sending request to router and waiting for response")
    net.sendMessage(computerData.gatewayIp, payload)
    local _, _, _, _, _, sdata = event.pullFiltered(ROUTER_RESP_TTL, eventFilter)

    if sdata == nil then
        print("router did not respond")
        return nil
    end

    local data = serialization.unserialize(sdata)
    if data == nil then
        return nil, "Router did not respond"
    end
    if data.body == nil then
        return nil, "Response error"
    end
    if data.body.title == "PMA" then
        if callbackFunc ~= nil then
            editForwardedPort(data.body.port, callbackFunc)
        elseif callback ~= nil then
            editForwardedPort(data.body.port, callback)
        else
            editForwardedPort(data.body.port, dummy)
        end
        return data.body.port, "SUCCESS"
    else
        return nil, data.body.err
    end
end

function net.getForwardingTable(ip)
    local payload = {
        title = "PMTGET"
    }
    if ip ~= nil then
        payload.ip = ip
    end

    local function eventFilter(name, ...)
        if name ~= "modem_message" then
            return false
        end
        local sdata = select(5, ...)
        local data = serialization.unserialize(sdata)

        if data.HEADER and data.HEADER.DA == computerData.ip then
            if data.body and data.body.title == "PMTRESP" then
                return true
            end
        end
        return false
    end

    print("Sending request to router and waiting for response")
    net.sendMessage(computerData.gatewayIp, payload)
    local _, _, _, _, _, sdata = event.pullFiltered(ROUTER_RESP_TTL, eventFilter)

    if sdata == nil then return nil end

    return serialization.unserialize(sdata).body.PMT
end

function net.getARPTable()
    local payload = {
        title = "ARPGET"
    }

    local function eventFilter(name, ...)
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

    local arp = serialization.unserialize(sdata).body.ARP
    arp.i = nil

    return arp
end

function net.getNATTable()
    local payload = {
        title = "NATGET"
    }

    local function eventFilter(name, ...)
        if name ~= "modem_message" then
            return false
        end
        local sdata = select(5, ...)
        local data = serialization.unserialize(sdata)

        if data.HEADER and data.HEADER.DA == computerData.ip then
            if data.body and data.body.title == "NATRESP" then
                return true
            end
        end
        return false
    end

    print("Sending request to router and waiting for response")
    net.sendMessage(computerData.gatewayIp, payload)
    local _, _, _, _, _, sdata = event.pullFiltered(ROUTER_RESP_TTL, eventFilter)
    if sdata == nil then return nil end

    local udata = serialization.unserialize(sdata)
    return udata.NAT, udata.NAT_TTL
end

function net.debug()
    for i, j in pairs(computerData) do print(i, j) end
end

function net.isIpLan(ip)
    -- TODO match subnet mask
    if string.find(ip, "10.0.0") == nil then
        return false
    else
        return true
    end
end

function net.sendMessage(ip, body, port)
    if not computerData.ip or not computerData.gatewayAddr then
        print("lib not initialized correctly, ip was not assigned to this pc. did you load()?")
    end

    local payload = serialization.serialize({
        HEADER = {
            SA = computerData.ip,
            DA = ip,
            DP = port -- if the message is routed to LAN this should be nil (if not nil the router will discard it anyway)
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
        print("MESSAGE RECEIVE", sdata)
        if (computerData.publicIP and data.HEADER.DA) and (data.HEADER.DA == computerData.publicIP) then
            -- Dest Ip is publicIP then message is coming from WAN
            if data.HEADER.DP == nil then
                -- something wrong with router if this triggers
                print("Received WAN message without port, dropping")
            end
            if data.HEADER.DP and net.isForwardedPort(data.HEADER.DP) then
                -- message from WAN to a forwarded port, call callback passing it whole data table
                print("Forwarding WAN message to forwarded port callback (".. data.HEADER.DP ..")")
                forwardedPorts[data.HEADER.DP](data)
                return
            end
            if data.HEADER.DP and net.isEphemeralPort(data.HEADER.DP) then
                if callback then
                    print("Forwarding WAN message to allback (".. data.HEADER.DP ..")")
                    callback(data)
                    return
                end
            else
                print("Received WAN message but no open port was found for it\n DEBUG", serialization.serialize(data))
                return
            end
        end
    else
        -- data was sent with no HEADER, maybe it's from an unrelated script?
        print("Received data with no header, discarding")
        return
    end

    if data.body.title and data.body.title == "DHCPDISCOVER" then
        if data.HEADER.SA and data.HEADER.SA == computerData.gatewayIp then
            local payload = {
                HEADER = {
                    SA = computerData.ip,
                    DA = computerData.gatewayIp
                },
                body = {
                    title = "ACK_LAN", -- all needed data is in header
                }
            }
            modem.send(senderAddr, modemPort, serialization.serialize(payload))
        else
            return -- another LAN computer wants an IP, packet is useless to us, drop
        end
    end

    -- if both HEADER.DA and HEADER.DADDR are nil then the message was broadcasted to everyone.

    -- print("ACCEPTED MSG", "FROM " .. data.HEADER.SA, "TO " .. data.HEADER.DA..":"..data.HEADER.DADDR, "TITLE ", data.body.title)

    local body = data.body

    if body and body.title then
        if body.title == "DHCPOFFER" then -- save DHCP data
            computerData.ip = body.ip
            computerData.gatewayIp = body.gateway.ip
            computerData.gatewayAddr = body.gateway.address
            computerData.publicIP = body.gateway.public_ip

            print("ACK DHCP", "IP " .. computerData.ip, "FROM " .. computerData.gatewayIp .. " " .. computerData.gatewayAddr)

            if callback then callback("Assigned IP: " .. computerData.ip) end
            return

        elseif body.title == "SYN_INIT" then -- router restarted
            if data.body.gateway and data.body.gateway ~= computerData.gatewayIp then
                -- computers will only talk to the last router that initializes
                computerData.gatewayIp = data.body.gateway
                computerData.gatewayAddr = senderAddr
            end

            local payload = {
                HEADER = {
                    SA = computerData.ip,
                    DA = computerData.gatewayIp
                },
                body = {
                    title = "ACK_INIT", -- all needed data is in header
                }
            }
            modem.send(senderAddr, modemPort, serialization.serialize(payload))

        elseif body.title == "EPORTFWD" then
            if body.port then
                addEphemeraPort(body.port)
            else
                print("got EPORTFWD message without port:\n", data)
            end
            return

        elseif body.title == "EPORTCLOSE" then
            if body.port then
                removeEphemeraPort(body.port)
            else
                print("got EPORTCLOSE message without port:\n", data)
            end
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
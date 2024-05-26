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
    gateway_addr = nil,
    gateway_ip = nil,
    publicIp = nil,
    subnetMask = nil -- TODO implement
}

local defaultCallback = nil
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

local function cidrToDot(cidr)
    local prefix = tonumber(cidr:match("/(%d+)$"))
    local mask = (2^32 - 1) - (2^(32 - prefix) - 1)
    local octets = {}
    for i = 1, 4 do
        table.insert(octets, 1, math.floor(mask % 256))
        mask = math.floor(mask / 256)
    end
    return table.concat(octets, ".")
end

local function dotToCIDR(mask, ip)
    local bits = 0
    for octet in mask:gmatch("(%d+)") do
        local num = tonumber(octet)
        while num > 0 do
            bits = bits + (num % 2)
            num = math.floor(num / 2)
        end
    end
    return (ip or "") .. "/" .. bits
end

local function ipToInt(ip)
    local octets = {ip:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")}
    local ip_int = 0
    for i, octet in ipairs(octets) do
        ip_int = ip_int + tonumber(octet) * (256 ^ (4 - i))
    end
    return ip_int
end

local function cidrToNetmask(cidr)
    local ip, prefix = cidr:match("(%d+%.%d+%.%d+%.%d+)/(%d+)")
    local mask = (2^32 - 1) - (2^(32 - tonumber(prefix)) - 1)
    return ipToInt(ip), mask
end

local function isIP(str)
    local ipv4_pattern = "^%d+%.%d+%.%d+%.%d+$"
    if string.match(str, ipv4_pattern) then
        return true
    end
    return false
end

local function isIpInSubnet(ip, subnet)
    if isIP(subnet) then
        subnet = dotToCIDR(subnet, computerData.gateway_ip)
    end
    local ip_int = ipToInt(ip)
    local network, mask = cidrToNetmask(subnet)
    return (ip_int & mask) == (network & mask)
end

local function generateShortUUID()
    local random = math.random
    local template ='xxxxxxxxxxxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function (c)
        local v = (c == 'x') and random(0, 0xf) or random(8, 0xb)
        return string.format('%x', v)
    end)
end

function net.sendMessage(ip, body, port)
    if not computerData.ip or not computerData.gateway_addr then
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

    print("DEBUG", "modem_send ".. computerData.gateway_addr, modemPort, payload)
    modem.send(computerData.gateway_addr, modemPort, payload)
end

local function sendRequestAndAwaitResponse(requestPayload, timeout)
    local uuid
    if requestPayload and requestPayload.HEADER and requestPayload.HEADER.uuid then
        uuid = requestPayload.HEADER.uuid
    else
        uuid = generateShortUUID()
        requestPayload.HEADER.uuid = uuid
    end

    local function eventFilter(name, ...)
        if name ~= "modem_message" then
            return false
        end
        local sdata = select(5, ...)
        local data = serialization.unserialize(sdata)

        if data.HEADER and data.HEADER.uuid == uuid and data.HEADER.DA == computerData.ip then
            if data.body then
                return true
            end
        end
        return false
    end
    print("Sending request and waiting for response", uuid)

    modem.send(computerData.gateway_addr, modemPort, serialization.serialize(requestPayload))
    local _, _, _, _, _, sdata = event.pullFiltered(timeout or ROUTER_RESP_TTL, eventFilter)
    if sdata == nil then    return nil, "did not respond"   end

    local data = serialization.unserialize(sdata)
    if data.body == nil then
        print("Err: accepted response with no body", sdata)
        return nil, "Response had no body"
    end
    return data
end


function net.load(c, doPrintDebug) -- load the lib, provide a callback to read incoming messages from both LAN and WAN
    defaultCallback = c
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
        ip = computerData.ip, 
        gateway = computerData.gateway_ip,
        subnet = computerData.subnetMask,
        addr = computerData.networkAddr,
        public_ip = computerData.public_ip,
        isp_ip = computerData.isp_ip
    }
end

function net.resolveDomain(domain)
    local req = {
        HEADER = {
            SA = computerData.ip,
            DA = computerData.isp_ip,
            DP = 53
        },
        body = {
            title = "DNS_RESOLVE",
            domain = domain
        }
    }

    local data, err = sendRequestAndAwaitResponse(req, ROUTER_RESP_LONG_TTL)
    if err ~= nil or data == nil then return nil, (err or "unknown error") end

    if data.body.title == "DNS_DENY" then
        return nil, nil, data.body.reason
    else
        return data.body.ip, data.body.port, nil
    end
end

function net.askDomainName(domain)
    local req = {
        HEADER = {
            SA = computerData.ip,
            DA = computerData.isp_ip,
            DP = 53
        },
        body = {
            title = "DNS_POST",
            domain = domain,
            ip = computerData.public_ip
        }
    }

    local data, err = sendRequestAndAwaitResponse(req, ROUTER_RESP_LONG_TTL)
    if err ~= nil or data == nil then return nil, (err or "unknown error") end

    if data.body.title == "DNS_DENY" then
        return nil, data.body.reason
    else
        return data.body.response, nil
    end
end

-- subdomains link to a specific OC in lan through an open port
function net.addSubdomain(domain, port)
    local req = {
        HEADER = {
            SA = computerData.ip,
            DA = computerData.isp_ip,
            DP = 53
        },
        body = {
            title = "DNS_PUT",
            domain = domain,
            port = port
        }
    }

    local data, err = sendRequestAndAwaitResponse(req, ROUTER_RESP_LONG_TTL)
    if err ~= nil or data == nil then return nil, (err or "unknown error") end

    if data.body.title == "DNS_DENY" then
        return nil, data.reason
    else
        return data.body.response, nil
    end
end

function net.getRouterInfo()
    local req = {
        HEADER = {
            SA = computerData.ip,
            DA = computerData.gateway_ip
        },
        body = {
            title = "GET-ROUTERINFO"
        }
    }

    local data, err = sendRequestAndAwaitResponse(req)
    if err ~= nil or data == nil then return nil, (err or "unknown error") end

    return data.body.info
end

function net.requestPortMapping(port, customCallback)
    local req = {
        HEADER = {
            SA = computerData.ip,
            DA = computerData.gateway_ip
        },
        body = {
            title = "NCC",
            req = {
                title = "PMR",
                external_port = port
            }
        }
    }

    local data, err = sendRequestAndAwaitResponse(req)
    if err ~= nil or data == nil then return nil, (err or "unknown error") end

    if data.body.title == "PMA" then
        if customCallback ~= nil then
            editForwardedPort(data.body.port, customCallback)
        elseif defaultCallback ~= nil then
            editForwardedPort(data.body.port, defaultCallback)
        else
            editForwardedPort(data.body.port, dummy)
        end
        return data.body.port, nil
    else
        return nil, (data.body.err or "unknown error")
    end
end

function net.getForwardingTable(ip)
    local req = {
        HEADER = {
            SA = computerData.ip,
            DA = computerData.gateway_ip
        },
        body = {
            title = "PMTGET",
            ip = (ip or nil)
        }
    }

    local data, err = sendRequestAndAwaitResponse(req)
    if err ~= nil or data == nil then return nil, (err or "unknown error") end

    return data.body.PMT
end

function net.getARPTable()
    local req = {
        HEADER = {
            SA = computerData.ip,
            DA = computerData.gateway_ip
        },
        body = {
            title = "ARPGET",
        }
    }

    local data, err = sendRequestAndAwaitResponse(req)
    if err ~= nil or data == nil then return nil, (err or "unknown error") end

    local arp = data.body.ARP
    arp.i = nil

    return arp
end

function net.getNATTable()
    local req = {
        HEADER = {
            SA = computerData.ip,
            DA = computerData.gateway_ip
        },
        body = {
            title = "NATGET",
        }
    }

    local data, err = sendRequestAndAwaitResponse(req)
    if err ~= nil or data == nil then return nil, (err or "unknown error") end

    return data.body.NAT, data.body.NAT_TTL
end

function net.debug()
    for i, j in pairs(computerData) do print(i, j) end
end

function net.isIpLan(ip)
    if not isIP(ip) then    return false    end
    return isIpInSubnet(ip, computerData.subnet_mask)
end

local function modemReceive(_, _, senderAddr, port, _, sdata)
    local data = serialization.unserialize(sdata)
    if data.HEADER then
        if data.HEADER.DADDR and (data.HEADER.DADDR ~= computerData.networkAddr) then
            return -- Dest Addr was not this pc, so definitely discard message  
        end
        if data.HEADER.uuid then return end -- response was for a function listening elsewere

        print("MESSAGE RECEIVE", sdata)
        if (computerData.public_ip and data.HEADER.DA) and (data.HEADER.DA == computerData.public_ip) then
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
                if defaultCallback then
                    print("Forwarding WAN message to callback (".. data.HEADER.DP ..")")
                    defaultCallback(data)
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
        if data.HEADER.SA and data.HEADER.SA == computerData.gateway_ip then
            local payload = {
                HEADER = {
                    SA = computerData.ip,
                    DA = computerData.gateway_ip
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
            computerData.subnet_mask = body.gateway.subnet_mask
            computerData.gateway_ip = body.gateway.ip
            computerData.gateway_addr = body.gateway.address
            computerData.public_ip = body.gateway.public_ip
            computerData.isp_ip = body.isp

            print("ACK DHCP", "IP " .. computerData.ip, "FROM " .. computerData.gateway_ip .. " " .. computerData.gateway_addr)

            if defaultCallback then defaultCallback("Assigned IP: " .. computerData.ip) end
            return

        elseif body.title == "SYN_INIT" then -- router restarted
            if data.body.gateway and data.body.gateway ~= computerData.gateway_ip then
                -- computers will only talk to the last router that initializes
                computerData.gateway_ip = data.body.gateway
                computerData.gateway_addr = senderAddr
            end

            local payload = {
                HEADER = {
                    SA = computerData.ip,
                    DA = computerData.gateway_ip
                },
                body = {
                    title = "ACK_INIT", -- all needed data is in header
                }
            }
            modem.send(senderAddr, modemPort, serialization.serialize(payload))

        elseif body.title == "EPORTFWD" then
            if body.port then
                print("new eph port: ".. body.port)
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
            if defaultCallback and body.message then
                print("ACK MSG", "FROM " .. data.HEADER.SA, "TO " .. data.HEADER.DA)
                defaultCallback(body.message)
            else
                print("Received message but there was no callback")
            end
            return

        elseif body.title == "STRING" then
            if defaultCallback and body.message then
                print("ACK STRING", "FROM " .. data.HEADER.SA, "TO " .. data.HEADER.DA)
                defaultCallback(body.message)
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
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
local DNS = {}

modem.open(ispData.reqPort)
modem.open(ispData.respPort)

local function cleanDomainString(string)
    local parts = {}
    for part in string:gmatch("[^.]+") do
        table.insert(parts, part)
    end

    -- Retain the last two parts as main domain
    local num_parts = #parts
    if num_parts >= 2 then
        -- If there are at least two parts, remove the subdomain
        return parts[num_parts - 1] .. ".mc"
    else
        -- If there are fewer than 2 parts, return the original domain
        return string
    end
end

local function extractSubdomain(domain)
    -- Split the string into parts using dot as delimiter
    local parts = {}
    for part in domain:gmatch("[^.]+") do
        table.insert(parts, part)
    end

    -- If there are more than two parts, extract subdomain
    if #parts > 2 then
        -- Construct subdomain by joining all parts except the last two
        local subdomain_parts = {}
        for i = 1, #parts - 2 do
            table.insert(subdomain_parts, parts[i])
        end
        return table.concat(subdomain_parts, ".")
    else
        -- No subdomain present
        return ""
    end
end

-- DNS = {
--     notlatif = {
--         ip = "2323231",
--         sub = {
--             br = "80"
--         }
--     }
-- }
local function resolveDNS(domain)
    local DNSEntry = DNS[cleanDomainString(domain)]
    if DNSEntry then
        local sub = DNSEntry.sub[extractSubdomain(domain)]
        if sub then
            return DNSEntry.ip, sub
        else
            return DNSEntry.ip
        end
    end

    return nil
end

local function removeEntryToDSN(domain)
    local cleanedDomain = cleanDomainString(domain)
    if cleanedDomain == "" then return false, "emp" end

    if DNS[cleanedDomain] then
        DNS[cleanedDomain] = nil
        return true
    else
        return false, "Record "..cleanedDomain.." did not exist"
    end
end

local function saveEntryToDSN(domain, ip)
    -- detect subdomains
    local cleanedDomain = cleanDomainString(domain)
    if cleanedDomain == "" then return nil end

    if DNS[cleanedDomain] then
        return nil, "Entry already exists."
    else
        DNS[cleanedDomain] = {
            ip = ip,
            sub = {}
        }
        print("successfully added DNS entry for " .. ip .. " ".. domain, cleanedDomain)
        return cleanedDomain .. ".mc"
    end
end
local function addSubdomainToDSN(domain, port)
    local cleanedDomain = cleanDomainString(domain)
    local newSubdomain = extractSubdomain(domain)

    if cleanedDomain == "" then return nil end
    if port == nil then return nil, "Arg err no port" end

    if DNS[cleanedDomain] then
        if DNS[cleanedDomain]["sub"][newSubdomain] then
            return nil, "subdomain already exists"
        else
            DNS[cleanedDomain]["sub"][newSubdomain] = port
            print("successfully added subdomain "..domain, newSubdomain, port)
            return newSubdomain .. "." .. cleanedDomain .. ".mc"
        end
    else
        return nil, "domain does not exist"
    end
end

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
    if daddr == nil then print("Could not convert ip to address, not sending message") end
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

    if data.HEADER and data.HEADER.DA and data.HEADER.DA ~= ispData.ip then
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

    elseif data.body.title == "DNS_RESOLVE" then
        local ip, port = resolveDNS(data.body.domain)
        if ip ~= nil then
            local payload = serialization.serialize({
                HEADER = {
                    SA = ispData.ip,
                    DA = data.HEADER.SA,
                    DP = data.HEADER.SP,
                    SP = 53,
                    uuid = data.HEADER.uuid
                }, body = {
                    title = "DNS_ACK",
                    ip = ip,
                    port = port
                }
            })
            modem.send(saddr, ispData.respPort, payload)
        else
            local payload = serialization.serialize({
                HEADER = {
                    SA = ispData.ip,
                    DA = data.HEADER.SA,
                    DP = data.HEADER.SP,
                    SP = 53,
                    uuid = data.HEADER.uuid
                }, body = {
                    title = "DNS_DENY",
                    reason = "Could not resolve Domain name " .. data.body.domain
                }
            })
            modem.send(saddr, ispData.respPort, payload)
        end

    elseif data.body.title == "DNS_POST" then
        local name, err = saveEntryToDSN(data.body.domain, data.body.ip)
        if name ~= nil then
            local payload = serialization.serialize({
                HEADER = {
                    SA = ispData.ip,
                    DA = data.HEADER.SA,
                    DP = data.HEADER.SP,
                    SP = 53,
                    uuid = data.HEADER.uuid
                }, body = {
                    title = "DNS_ACK",
                    response = name,
                }
            })
            modem.send(saddr, ispData.respPort, payload)
        else
            local payload = serialization.serialize({
                HEADER = {
                    SA = ispData.ip,
                    DA = data.HEADER.SA,
                    DP = data.HEADER.SP,
                    SP = 53,
                    uuid = data.HEADER.uuid
                }, body = {
                    title = "DNS_DENY",
                    response = nil,
                    reason = err
                }
            })
            modem.send(saddr, ispData.respPort, payload)
        end

    elseif data.body.title == "DNS_PUT" then
        local name, err = addSubdomainToDSN(data.body.domain, data.body.port)
        if name ~= nil then
            local payload = serialization.serialize({
                HEADER = {
                    SA = ispData.ip,
                    DA = data.HEADER.SA,
                    DP = data.HEADER.SP,
                    uuid = data.HEADER.uuid
                }, body = {
                    title = "DNS_ACK",
                    response = name,
                }
            })
            modem.send(saddr, ispData.respPort, payload)
        else
            local payload = serialization.serialize({
                HEADER = {
                    SA = ispData.ip,
                    DA = data.HEADER.SA,
                    DP = data.HEADER.SP,
                    uuid = data.HEADER.uuid
                }, body = {
                    title = "DNS_DENY",
                    response = nil,
                    reason = err
                }
            })
            modem.send(saddr, ispData.respPort, payload)
        end

    elseif data.body.title == "DNS_DEL" then
        local succ = removeEntryToDSN(data.body.domain)
        local payload = serialization.serialize({
            HEADER = {
                SA = ispData.ip,
                DA = data.HEADER.SA,
                DP = data.HEADER.SP,
                uuid = data.HEADER.uuid
            }, body = {
                title = "DNS_ACK",
                response = succ and "successfully deleted" or "did not delete",
            }
        })
        modem.send(saddr, ispData.respPort, payload)

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
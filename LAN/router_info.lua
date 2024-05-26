-- small interface to view and edit connected router
local io = require("io")
local package = require("package")
local serialization = require("serialization")
if package.loaded.net then package.loaded.net = nil end

local net = require("net")

local ready = false

local function netCallback(data)
    print("CBK:", serialization.serialize(data))
end

local function wanResponseCallback(data)
    print("Message response on port ".. data.HEADER.DP .."\n" .. serialization.serialize(data))
end

net.load(netCallback, true)

local function printMenu()
    print("[I] view computer and router network info")
    print("[S] send a message to another computer")
    print("[P] send a port mapping request")
    -- print("[P-] send a port mapping remove request")
    print("[N] view router ARP table")
    print("[T] get router NAT table")
    print("[F] get router forwarding table")
    print("[F+] get router forwarding table for this computer")
    print("[D] ask new domain name for this pc's public ip")
    print("[DS] add subdomain to domain and link it to this pc")
end

while not ready do
    if net.getNetworkCardData().ip ~= nil then
        ready = true
    end
    os.sleep(0.5)
end

local function main()
    printMenu()
    local resp = io.read()
    if resp == "I" or resp == "i" then
        local computerNetInfo = net.getNetworkCardData()
        print("- NETWORK CARD -")
        for i,j in pairs(computerNetInfo) do
            print(i, j)
        end

        local routerNetInfo = net.getRouterInfo()
        if routerNetInfo == nil then
            print("Router did not respond.")
            return
        end
        print("- ROUTER -")
        for i,j in pairs(routerNetInfo) do
            print(i, j)
        end
    
    elseif resp == "N" or resp == "n" then
        local arp = net.getARPTable()
        if arp then
            for i,j in pairs(arp) do
                print(i ,j)
            end
        else
            print("Router did not respond.")
        end

    elseif resp == "S" or resp == "s" then
        print("Ender destination IP address [or domain (WIP)]")
        local destip = io.read()

        local destport = nil
        if not net.isIpLan(destip) then
            print("The ip provided is not in LAN, please specify a port")
            destport = io.read()
        end

        print("Enter message string")
        local msg = io.read()
        local payload = {
            title = "STRING",
            message = msg
        }
        net.sendMessage(destip, payload, destport)

    elseif resp == "T" or resp == "t" then
        local nat, natttl = net.getNATTable()
        if nat == nil then
            print("Response was empty")
            return
        end

        print("local_ip","local_port","remote_ip","remote_port", "TTL")
        local cTime = os.time()
        for k, v in pairs(nat) do
            print(v.localIP, v.localPort, v.remoteIP, v.remotePort, cTime - v.TTL)
        end
    
    elseif resp == "P" or resp == "p" then
        print("Enter port you want to forward to this OC")
        local extPort = io.read()
        local p, e = net.requestPortMapping(extPort, wanResponseCallback)
        if p ~= nil then
            print("succesfully forwarded port: " .. p)
        else
            print("could not forward port: ", e)
        end
    
    elseif resp == "F" or resp == "f" then
        local fTable = net.getForwardingTable()
        if fTable ~= nil then
            for p, i in pairs(fTable) do
                print(i, p)
            end
        else
            print("Router did not respond.")
        end

    elseif resp == "F+" or resp == "f+" then
        local fTable = net.getForwardingTable(net.getNetworkCardData().ip)
        if fTable ~= nil then
            for p, i in pairs(fTable) do
                print(i, p)
            end
        else
            print("Router did not respond.")
        end

    elseif resp == "D" or resp == "d" then
        print("Enter the domain name you want to request without any subdomains")
        local dom = io.read()
        local r, err = net.askDomainName(dom)
        print(r, err)

    elseif resp == "DS" or resp == "ds" then
        print("Specify the domain and subdomain <eg: test.example.mc>")
        local dom = io.read()
        print("Specify the port you want to link")
        local p = io.read()
        if not net.isForwardedPort(p) then
            local _, e = net.requestPortMapping(p)
            if e then
                print("could not forward port " .. p, e)
            end
        end

        local r, err = net.addSubdomain(dom, p)

        print(r, err)
    end
end

while true do
    main()
end
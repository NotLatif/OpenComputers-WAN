-- small interface to view and edit connected router
local io = require("io")
local package = require("package")
local serialization = require("serialization")
if package.loaded.lan then package.loaded.lan = nil end

local net = require("lan")

local function netCallback(data)
    print(serialization.serialize(data))
end

net.load(netCallback, false)

local function printMenu()
    print("[I] view computer and router network info")
    print("[N] view router ARP table")
    print("[S] send a message to another computer")
end

local function main()
    printMenu()
    local resp = io.read()
    if resp == "I" or resp == "i" then
        local computerNetInfo = net.getNetworkCardData()
        local routerNetInfo = net.getRouterInfo()

        print("- NETWORK CARD -")
        for i,j in pairs(computerNetInfo) do
            print(i, j)
        end

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
        print("Ender destination IP address or domain [WIP]")
        local destip = io.read()
        print("Enter message string")
        local msg = io.read()
        local payload = {
            title = "STRING",
            message = msg
        }
        net.sendMessage(destip, payload)
    end
end

while true do
    main()
end
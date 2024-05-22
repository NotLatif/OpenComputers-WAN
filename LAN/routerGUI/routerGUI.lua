-- program that allows editing of router settings through a gui
local os = require("os")
local event = require("event")
local component = require("component")
local serialization = require("serialization")

if package.loaded.wAPI then package.loaded.wAPI = nil end
if package.loaded.lan then package.loaded.lan = nil end
local net = require("net")
local wAPI = require("wapi")

local gpu = component.gpu
local exit = false

local function netCallback(data)
    print(serialization.serialize(data))
end

net.load(netCallback, false)

while net.getNetworkCardData().ip == nil do
    os.sleep(0.25)
end

local gateway = net.getNetworkCardData().gateway

local w, h = gpu.getViewport()

local color = {    blue = 0x4286F4, purple = 0xB673d6, red = 0xC14141, 
                    green = 0xDA841, black = 0x000000, white = 0xFFFFFF, 
                    gray = 0x47494C, lightGray = 0xBBBBBB, darkGray = 0x202020,
                    yellow = 0xFFE800, cyan = 0x00FFFF, orange = 0xFF984F,
                    crimson = 0xFF5733}


local activePage = 0
local widgets = {
    custom = {
        header = {x=1, y=1, w=w, h=1, col=color.gray}
    },
    page0 = {},
    header = {}
}

local function cls(keepHeader)
    if keepHeader == nil then keepHeader = false end
    local sy = (keepHeader and 2) or 1
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, sy, w, h, " ")
end

local function render(data, isText)
    if isText == nil then isText = false end
    local lastbg, ispalettebg = gpu.getBackground()

    gpu.setBackground(data.col)
    if isText then
        gpu.set(data.x, data.y, data.text)
    else
        gpu.fill(data.x, data.y, data.w, data.h, " ")
    end
    gpu.setBackground(lastbg, ispalettebg)
end

local function loadPage()
    cls()
    if activePage == 0 then
        render(widgets.custom.header)
        for _, d in pairs(widgets.header) do
            d:render()
        end
        for _, d in pairs(widgets.page0) do
            d:render()
        end

    end
end

local routerData = {ARP = {}, NAT = {}, NET = {}, FWD = {}, etimerid = nil}

local function fetchRouterData()
    routerData.ARP = net.getARPTable()
    routerData.NAT = net.getNATTable()
    routerData.NET = net.getNetworkCardData()
    routerData.FWD = net.getForwardingTable()
end


local function init()
    cls()
    render(widgets.custom.header)

    widgets.header["hederDiv"] = wAPI.newPushdiv({x=1,y=1}, {h=1}, nil, 2, color.gray,
        wAPI.newLabel("", {}, color.gray, nil),
        wAPI.newLabel(gateway, {}, color.gray, nil),
        
        wAPI.newBtn("Overview", {}, {ml=1, mr=1}, {active=color.green,onclick=color.blue}, nil, "l", function ()
            activePage = 0
            cls(true)
        end),

        wAPI.newBtn("Wi-Fi", {}, {ml=1, mr=1}, {active=color.green,onclick=color.blue}, nil, "l", function ()
            activePage = 1
            cls(true)
        end),

        wAPI.newBtn("Traffic", {}, {ml=1, mr=1}, {active=color.green,onclick=color.blue}, nil, "l", function ()
            activePage = 2
            cls(true)
        end)
        
    )

    widgets.header["lblTitle"] = wAPI.newLabel(gateway, {x=2, y=1}, color.gray, nil):render()
    widgets.header["btnExit"] = wAPI.newBtn("Exit", {x=w-3, y=1}, {ml=1, mr=1}, {active=color.crimson, onclick=color.red}, nil, "r", function ()
        -- cancel callbacks and exit
        event.ignore("touch", Checkxy)
        if routerData.etimerid then event.cancel(routerData.etimerid) end
        print("Exiting")
        exit=true
    end)

    widgets.page0["ARP"] = wAPI.newLabel("LAN Computers", {x=3, y=4}, nil, nil)

    widgets.header["hederDiv"]:render()
    widgets.header["btnExit"]:render()

    -- load WIFI widgets
    widgets.page1["title"] = wAPI.newLabel("WiFi status: ".. "active", {x=2,y=5})
    
    
    fetchRouterData()
end


function Checkxy(_, _, x, y, _, _)
    local activeWidgets
    if activePage == 0 then
        activeWidgets = widgets.page0
    elseif activePage == 1 then

    end

    local function pCheck(widget)
        widget:checkAndClick(x, y, "Hi, I was clicked")
    end

    for _, b in pairs(widgets.header) do
        if b.clickable then
            local success, err = pcall(pCheck, b)
            if not success then
                print("Error in callback:", err)
            end
        end
    end
    for _, b in pairs(activeWidgets) do
        if b.clickable then
            local success, err = pcall(pCheck, b)
            if not success then
                print("Error in callback:", err)
            end
        end
    end
end

event.listen("touch", Checkxy)
routerData.etimerid = event.timer(20, fetchRouterData)

init()

local function mainloop()
    if activePage == 0 then -- OVW page
        widgets.header["hederDiv"]:render()
        widgets.header["btnExit"]:render()
        for _, wg in pairs(widgets.page1) do
            wg:render()
        end

        widgets.page0.ARP:render()
        local offset = 0
        for j, i in pairs(routerData.ARP) do
            gpu.set(3, 5+offset, i)
            gpu.set(6+i:len(), 5+offset, j)
            offset = offset + 1 
        end
    
    elseif activePage == 1 then
        widgets.header["hederDiv"]:render()
        widgets.header["btnExit"]:render()

        for _, wg in pairs(widgets.page1) do
            wg:render()
        end

    elseif activePage == 2 then
        widgets.header["hederDiv"]:render()
        widgets.header["btnExit"]:render()

        for _, wg in pairs(widgets.page2) do
            wg:render()
        end
    end
    return 1
end

while event.pull(0.1, "interrupted") == nil do
    mainloop()
    if exit then break end
end
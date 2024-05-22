-- small client to test internet lib
local os = require("os")
local event = require("event")
local package = require("package")
local serialization = require("serialization")
if package.loaded.net then package.loaded.net = nil end

local net = require("net")

local function lanCallback(data)
    print(serialization.serialize(data))
end

net.load(lanCallback)

while event.pull(0.1, "interrupted") == nil do
    os.sleep()
end
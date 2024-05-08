local component = require("component")
local internet = require("internet")
local sh = require("shell")
local fs = require("filesystem")
local os = require("os")
local io = require("io")

local filename = "/router.lua"
local url = "https://raw.githubusercontent.com/NotLatif/OpenComputers-WAN/main/Router/router.lua"

local cwd = sh.getWorkingDirectory()
if fs.exists(cwd..filename) then
    print(filename .. " file already exists, do you want to verwrite it? [y/N]")
    local r = io.read()
    if r ~= "Y" and r ~= "y" then
        return
    end
end

print("Downloading file from GitHub...")
local response = internet.request(url)

local content = ""
for chunk in response do
    content = content .. chunk
end

if content == "" then
    print("internet response was empty, maybe the URL changed?")
    return
end

local f = io.open(cwd .. filename, "w")
if f then
    f:write(content)
    f:close()
    print("Saved file to " .. cwd..filename)
else
    print("There was an error opening file " .. cwd..filename)
end
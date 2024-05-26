-- program that forwards all wired messages to wireless
local computer = require("computer")
local component = require("component")

local m = component.proxy(component.list("modem", true)())
m.open(67)
while true do
  local sig, _, _, port, distance, msg = computer.pullSignal(1)
  if sig == "modem_message" then
    if distance ~= 0 then return end
    if not m.isOpen(port) then m.open(port) end
    m.broadcast(port, msg)
  end
end
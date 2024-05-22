---@diagnostic disable: undefined-global
-- since it's difficult to determine which network card is assigned to LAN in a rack
-- and since wireless signals have a range
-- you can put a computer with a WAP whereever you want and it will forward lan messages
-- to "wifi"
local m = component.proxy(component.list("modem", true)())
m.open(67)

while true do
  local sig, _, _, port, distance, smsg = computer.pullSignal(1)
  if sig == "modem_message" then
    if distance ~= 0 then
        m.broadcast(port, smsg)
    end
  end
end
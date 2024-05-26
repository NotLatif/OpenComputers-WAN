---@diagnostic disable: undefined-global
-- since it's difficult to determine which network card is assigned to LAN in a rack
-- and since wireless signals have a range
-- you can put a computer with a WAP whereever you want and it will forward lan messages
-- to "wifi"
local function unserialize(str)
  local result, err = load("return " .. str, "unserialize", "t", {})
  if not result then
    error("Failed to unserialize: " .. err)
  end
  return result()
end

local function serialize(value)
  local serialized = ""

  local function serializeTable(t)
    local result = "{"
    for k, v in pairs(t) do
      local key
      if type(k) == "string" then
        key = string.format("[%q]", k)
      else
        key = "[" .. tostring(k) .. "]"
      end

      local value
      if type(v) == "table" then
        value = serializeTable(v)
      elseif type(v) == "string" then
        value = string.format("%q", v)
      else
        value = tostring(v)
      end

      result = result .. key .. "=" .. value .. ","
    end
    return result .. "}"
  end

  if type(value) == "table" then
    serialized = serializeTable(value)
  elseif type(value) == "string" then
    serialized = string.format("%q", value)
  else
    serialized = tostring(value)
  end

  return serialized
end

local m = component.proxy(component.list("modem", true)())
m.open(67)

local routerData

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

while true do
  local sig, _, _, port, distance, smsg = computer.pullSignal(1)
  local msg = unserialize(smsg)
  if sig == "modem_message" then
    if distance ~= 0 then
      if msg and msg.HEADER and msg.HEADER.SA == "10.0.0.0" then
        if msg.body then
          if msg.body.
        end
        m.broadcast(port, smsg)
      end
      return -- wifi message
    end

    m.broadcast(port, smsg)
  end
end
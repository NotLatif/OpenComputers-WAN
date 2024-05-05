# OC WAN
 **Very basic** WAN simulation for opencomputers

everything is more of a simulation than an implementation, I'm making this to connect opencomputers of my friends bases and facilities. 

## why?
idk but I guess I'm having fun

## features
- installation scripts
- LAN communications
- WAN communications (routers)
- ISP to connect multiple routers
- DHCP assignment to WAN and LAN
- ARP/NAT tables to avoid broadcasting

## usage
right now I only tested LAN messages which you can send using `LAN/router_info.lua` script on one OC and have it read by the `LAN/client.lua` script on another OC connected in a LAN with a Router (see below how)

every `(part)` is a different computer; `-` rapresent cable connections (wlan not yet implemented)

(LAN1) - (`Router/router.lua`) - (`ISP/ISP.lua`)
This is an example of a simple network, you have to run the scripts in order (ISP -> Router -> LAN). 

The Router must be in a rack, it needs two network cards connected to different sides, the script automatically determines which one is facing WAN and LAN

LAN1 must have the `LAN/lan.lua` lib to be able to use the client scripts, you can write your own client following the examples provided in the `LAN` folder (not recommended right now, things most likely WILL change)

## current status
- as mentioned, WIP
- nothing is saved to memory right now, so state is preserved as long as the scripts stay loaded
- please see [TODO.md](TODO.md) for future features

## terminology
since address and ip address are confusing, in the script whenevery I mention "ADDR" or "ADDRESS" I refer to an opencomputer network card address. If I mention "DA", "SA" or "IP" I refer to an IP Address (Destination, Sender, IP)
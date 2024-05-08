- (mostly working) port forwarding to allow WAN communications between computers

- NAT refine, fix bugs (ephemeral ports seem to not be working)

- improve local ip assigning logic to reuse expired IPs (so also implement ip expiration) ?
- Wireless LAN?
- auto refresh
- DHCP acknowledge? idk maybe
- - TCP protocol (unlikely)

- add connection to real internet through the OC internet API at the ISP level (maybe also at the router level?)
- add DNS and domain system (maybe as an app at the LAN level that sends messages to the ISP), DNS server is behind a router, allow the router to ask ISP for a public ip change (eg so the DNS server can ask to be behind 1.1.1.1)
- create router GUI with settings (maybe port forwarding (even if OC ports don't work this way))
- try to minimize friction between modem component api and WAN type requests to easily allow already existing scripts to be able to use WAN (maybe a special computer before the router at the LAN level that forwards messages from specific ports to the WAN (configurable through a GUI or CLI))

- make lan.lua a background "daemon" so that every script has the same IP address
- if possible, with the lan daemon make it so internet API can work over the WAN and ISP if an internet card is not installed in the opencomputer

- LAN/RouterGUI.lua to manage the router from an OC in LAN
- change terminology ADDR to MAC ? it's still a MAC "address" though...
- ISP ACK ? maybe not
- installation scripts

- save tables to files for persistence after restart

- WAP microcontroller
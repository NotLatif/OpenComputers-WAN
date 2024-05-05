- port forwarding to allow WAN communications between computers
- figure out why client.lua intercepts messages sent to another address
- automatically detect LAN clients after router restart

- implement NAT
- - ports used for communications will be the first part of the network card address (the one before the very first dash)

- installation scripts for ease of infrastructure installation

- change ports for realism?
- Wireless LAN?
- DHCP acknowledge? idk maybe
- add connection to real internet through the OC internet API at the ISP
- add DNS and domain system (maybe as an app at the LAN level that sends messages to the ISP)
- create router GUI with settings (maybe port forwarding (even if OC ports don't work this way))
- try to minimize friction between modem component api and WAN type requests to easily allow already existing scripts to be able to use WAN (maybe a special computer before the router at the LAN level that forwards messages from specific ports to the WAN (configurable through a GUI or CLI))
- create installers for every script in this projects
- make WAN.lua a background "daemon" so that every script has the same IP address

- if possible, with the WAN daemon make it so internet API can work over the WAN and ISP if an internet card is not installed in the opencomputer

- LAN/RouterGUI.lua to manage the router from an OC in LAN
- change terminology ADDR to MAC ? it's still a MAC "address" though...
- ISP ACK ? maybe not
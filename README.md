# wg-manager

Lightweight CLI tool to manage WireGuard peers for server-to-server VPN setups.

## Install

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/enavid/wg-manager/main/install.sh)
```

## Features

- Initialize a WireGuard server interactively
- Add peers with auto-assigned VPN IPs and auto-generated keypairs
- Remove peers cleanly from server config and live instance
- List all peers with VPN IPs and creation timestamps
- Print ready-to-paste client configs at any time
- All settings stored in `/etc/wg-manager/wg-manager.conf`
- Client configs saved in `/etc/wg-manager/clients/`

## Usage

```
wg-manager <command> [arguments]

COMMANDS
    init                Initialize the WireGuard server
    add   <name>        Add a new peer
    remove <name>       Remove a peer
    list                List all peers and live WireGuard status
    show  <name>        Print the client config for a peer
    status              Show server info and WireGuard status
    help                Show help
```

## Quick Start

```bash
sudo wg-manager init
sudo wg-manager add server-de-01
sudo wg-manager list
sudo wg-manager show server-de-01
sudo wg-manager remove server-de-01
```

## Requirements

- Ubuntu 22.04 / 24.04
- WireGuard: `apt install wireguard wireguard-tools`
- Root access

## License

MIT

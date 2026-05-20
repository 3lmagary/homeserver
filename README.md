# Proxmox & Home Server Setup Scripts

A collection of streamlined, automated setup scripts designed to quickly bootstrap a fresh Proxmox environment, LXC containers, and home server services.

## Overview

This repository contains scripts to automate repetitive tasks for Proxmox and self-hosted services, ensuring a secure and optimized baseline environment based on best practices.

## Available Scripts

### 1. Proxmox Safe Base Setup (`setup.sh`)
Automates the initial setup of a Proxmox node or a standard Debian/Ubuntu server.
- **System Updates**: Safe full system updates.
- **Essential Packages**: Installs necessary server tools (`curl`, `git`, `zsh`, `sudo`, `htop`, etc.).
- **User Management**: Prompts to create a new non-root user with `sudo` privileges.
- **Repository Management**: Disables Proxmox enterprise repo and enables the `pve-no-subscription` repo.
- **Terminal Beautification**: Configures `zsh` and `Starship` prompt for a sleek `~ ❯` interface.

**Usage:**
```bash
bash <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/setup.sh)
```

### 2. Ultimate DNS Setup: AdGuard Home + Unbound (`adguard_unbound.sh`)
Designed for an LXC container (Debian/Ubuntu) to run your own local DNS resolver and network-wide ad-blocker.
- **Port 53 Cleanup**: Safely disables `systemd-resolved` to prevent port conflicts (a common issue when setting up DNS servers).
- **Unbound Installation**: Configures Unbound as a recursive caching DNS resolver on port `5335`.
- **AdGuard Home**: Installs the latest version of AdGuard Home.
- **Integration Guide**: Provides post-installation instructions to link AdGuard Home to your local Unbound instance.

**Usage:**
*(Run this inside your LXC container)*
```bash
bash <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/adguard_unbound.sh)
```

#### Post-Installation for AdGuard Home
After running the `adguard_unbound.sh` script:
1. Open your browser and navigate to `http://<LXC_IP>:3000`.
2. Follow the setup wizard (use **Port 80** for the web interface and **Port 53** for the DNS server).
3. Once logged in, go to **Settings > DNS Settings**.
4. Set **Upstream DNS servers** to: `127.0.0.1:5335`
5. Set **Bootstrap DNS servers** to: `1.1.1.1`
6. Click **Apply** and then **Test upstreams** to verify everything is working.

## License

This project is open-source and available under the [MIT License](LICENSE). Feel free to fork and modify it to suit your specific needs.

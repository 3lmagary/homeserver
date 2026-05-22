<div align="center">
  <h1>🚀 Ultimate Home Server Setup</h1>
  <p><b>A modern, automated approach to bootstrapping Proxmox VE and Home Server LXC containers.</b></p>
  
  [![Proxmox VE](https://img.shields.io/badge/Proxmox-8.x_|_9.x-orange.svg?style=for-the-badge&logo=proxmox)](#)
  [![Shell Script](https://img.shields.io/badge/Shell_Script-121011?style=for-the-badge&logo=gnu-bash&logoColor=white)](#)
  [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](#)
</div>

---

## 📖 Overview

Setting up a home lab from scratch can be repetitive and tedious. This repository provides **production-ready bash scripts** designed to rapidly configure Proxmox nodes and LXC containers with industry best practices, saving you time and ensuring a secure baseline.

## 🛠️ Available Scripts

### 1️⃣ Proxmox Base Setup (`setup.sh`)
A foundational script for fresh Proxmox VE nodes. It handles repository management, creates a secure non-root user, sets up beautiful terminal aesthetics, and configures auto-login.

> **Note:** This script is fully **idempotent** — you can safely re-run it multiple times without breaking anything.

<details>
<summary><b>✨ View Features</b></summary>

- 🛠 **Smart Repo Fixes:** Automatically disables **all** paid Enterprise repos (PVE & Ceph, both `.list` and `.sources` formats) and adds the free No-Subscription repo. Dynamically detects the Debian codename (`bookworm`, `trixie`, etc.).
- 🔄 **Safe Updates:** Full system update & upgrade after repo cleanup.
- 📦 **Essential Tools:** Installs `curl`, `git`, `htop`, `sudo`, `zsh`, `nano`, `iotop`, `iftop`, and network tools.
- 👤 **Smart User Management:**
  - Auto-detects existing non-root users (skips system accounts like `ceph`).
  - Interactive username input with validation loop.
  - Supports non-standard usernames (e.g., starting with a number) via `--allow-bad-names` confirmation.
- 🎨 **Terminal Aesthetics:** Installs **Oh My Zsh** with the `robbyrussell` theme and essential plugins:
  - `zsh-autosuggestions` — Smart command auto-completion from history.
  - `zsh-syntax-highlighting` — Real-time syntax coloring (green = valid, red = invalid).
- 🔐 **Auto-Login:** Configures `tty1` for automatic console login with the created user.
</details>

**🚀 Run Command:**
```bash
bash <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/setup.sh)
```

---

### 2️⃣ AdGuard Home + Unbound (`adguard_unbound.sh`)
The ultimate local DNS setup script. Designed specifically to run inside an LXC container to provide a blazing-fast, ad-blocking recursive DNS resolver.

<details>
<summary><b>✨ View Features</b></summary>

- 🛑 **Port 53 Free-up:** Automatically detects and disables `systemd-resolved` conflicts.
- ⚡ **Unbound:** Configured securely as a recursive caching resolver on port `5335`.
- 🛡️ **AdGuard Home:** Installs the latest stable release.
</details>

**🚀 Run Command:**
*(Run this inside your LXC container)*
```bash
bash <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/adguard_unbound.sh)
```

#### ⚙️ AdGuard Configuration

Once the script finishes, complete the setup in your browser:

1. Go to `http://<YOUR_LXC_IP>:3000`
2. Follow the wizard (Web Interface: Port `80`, DNS Server: Port `53`).
3. Navigate to **Settings ➔ DNS Settings** in the dashboard.
4. Set **Upstream DNS servers** to:
   ```text
   127.0.0.1:5335
   ```
5. Set **Bootstrap DNS servers** to:
   ```text
   1.1.1.1
   ```
6. Click **Apply** and **Test upstreams**.

---

## 🤝 Contributing
Feel free to fork this repository, submit Pull Requests, or open Issues to suggest improvements or new scripts!

## 📜 License
Distributed under the MIT License. See `LICENSE` for more information.

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
*(Run as root on a fresh Proxmox install)*
```bash
bash <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/setup.sh)
```

---

### 2️⃣ Expandable NAS Setup (`nas_setup.sh`)
The ultimate, intelligent script to mount external hard drives (USB/SATA) and share them over the network (SMB/Samba) using a dynamically created, unprivileged LXC container.

> **Note:** Since the first script logs you in as a normal user, **you must use `sudo`** to run this script so it can interact with the Proxmox storage and LXC commands.

<details>
<summary><b>✨ View Features</b></summary>

- 💽 **Intelligent Disk Detection:** Scans for all connected hard drives and presents a numbered list (safely excluding your main Proxmox OS drive).
- 🔄 **Smart Formatting Logic:** 
  - If your drive is `ext4`, it proceeds seamlessly.
  - If your drive is `NTFS` or `exFAT`, it warns you and gives you the option to wipe it to `ext4` for maximum server performance, or keep it as is (automatically installing `ntfs-3g` / `exfat-fuse`).
- 📌 **Persistent Mounting:** Automatically extracts the UUID of your drive and adds it to `/etc/fstab` so it survives host reboots.
- 🐳 **Expandable LXC Architecture:** 
  - **First Run:** Creates a lightweight, unprivileged Debian 12 LXC container (`Samba-NAS`), installs Samba, and bind-mounts your drive securely.
  - **Subsequent Runs:** If you plug in a 2nd or 3rd hard drive, the script is smart enough to realize the `Samba-NAS` container already exists. It will NOT create a new container. Instead, it mounts the new drive and injects it into your existing container as a new folder!
- 🔐 **Security Choice:** Prompts you to either secure your share with a password (recommended) or create a public "Guest" share accessible to anyone on your network.
- 🛡️ **Proper UID Mapping:** Automatically handles complex UID/GID mappings (`101000:101000`) for `ext4` drives inside unprivileged containers to ensure you have write permissions.
</details>

**🚀 Run Command:**
*(Run from your Proxmox Host as a regular sudo user)*
```bash
sudo curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/nas_setup.sh | sudo bash
```

---

### 3️⃣ Sync & Backup Server (`sync_setup.sh`)
The ultimate all-in-one container for keeping your data safe and in sync across devices. It deploys **Syncthing** for massive file syncing/backups, and **CouchDB** for real-time `Obsidian LiveSync`.

> **Note:** Just like the NAS script, run this with `sudo` so it can scan physical drives and create the LXC.

<details>
<summary><b>✨ View Features</b></summary>

- 💽 **Optional Storage Binding:** Intelligently asks if you want to dedicate a physical hard drive to Syncthing (to store large backups/movies) or just use the LXC's internal storage.
- 🔄 **Syncthing (LAN-Only Mode):** Installs and configures Syncthing. Automatically disables Global Discovery, Relaying, and NAT Traversal so your data stays strictly on your local network for maximum privacy.
- 📓 **Obsidian LiveSync Ready:** 
  - Automatically installs `adduser` and dependencies, and pre-seeds all prompts to bypass interactive Debian blue screens.
  - Deploys **CouchDB** and explicitly binds it to `0.0.0.0` to allow external connections.
  - Automatically configures complex CORS headers via `curl` so the Obsidian plugin can connect immediately without errors.
- 🛡️ **Bulletproof Installation:** Includes background cleanup processes (`killall unattended-upgrades`, dpkg lock removal) to ensure the script runs flawlessly on the first try without hanging.
</details>

**🚀 Run Command:**
*(Run from your Proxmox Host as a regular sudo user)*
```bash
sudo curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/sync_setup.sh | sudo bash
```

---

## 🤝 Contributing
Feel free to fork this repository, submit Pull Requests, or open Issues to suggest improvements or new scripts!

## 📜 License
Distributed under the MIT License. See `LICENSE` for more information.

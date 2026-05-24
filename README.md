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

---

## 🛠️ Available Scripts

### 1️⃣ Proxmox Base Setup (`setup.sh`)

A foundational script for fresh Proxmox VE nodes. It handles repository management, creates a secure non-root user, sets up a beautiful terminal experience, and configures auto-login — all in one command.

> **Note:** This script is fully **idempotent** — you can safely re-run it multiple times without breaking anything.

<details>
<summary><b>✨ View Features</b></summary>

- 🛠 **Smart Repo Fixes:** Automatically disables **all** paid Enterprise repos (PVE & Ceph, both `.list` and `.sources` formats) and adds the free No-Subscription repo. Dynamically detects the Debian codename (`bookworm`, `trixie`, etc.).
- 🔄 **Safe Updates:** Full system update & upgrade after repo cleanup.
- 📦 **Essential Tools:** Installs `curl`, `git`, `htop`, `sudo`, `zsh`, `nano`, `iotop`, `iftop`, and network tools.
- 👤 **Smart User Management:**
  - Auto-detects existing non-root users (skips system accounts).
  - Interactive username input with validation and retry loop.
  - Supports non-standard usernames via `--allow-bad-names` confirmation.
- 🎨 **Terminal Aesthetics:** Installs **Oh My Zsh** with the `robbyrussell` theme and two essential plugins:
  - `zsh-autosuggestions` — Smart command auto-completion from history.
  - `zsh-syntax-highlighting` — Real-time syntax coloring.
- 🔐 **Auto-Login:**
  - Configures `tty1` for automatic physical console login.
  - Automatically switches from `root` to your user when opening the **Proxmox Web GUI Shell**.
</details>

**🚀 Run Command:**
*(Run as root on a fresh Proxmox install)*
```bash
bash <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/setup.sh)
```

---

### 2️⃣ Expandable NAS Setup (`nas_setup.sh`)

The ultimate, intelligent script to mount external hard drives (USB/SATA) and share them over the network (SMB/Samba) using a dynamically created, unprivileged LXC container.

> **Note:** Since the first script logs you in as a normal user, **you must use `sudo`** to run this script so it can interact with Proxmox storage and LXC commands.

<details>
<summary><b>✨ View Features</b></summary>

- 🛡️ **Foolproof Drive Detection:** Scans all connected drives and **completely hides your Proxmox OS disk** (and all its partitions) from the selection menu — making it impossible to accidentally format your system drive.
- 🧠 **Smart Drive Presentation:** If a drive is already partitioned (e.g. has `sdb1`), only the partition is shown — not the raw parent disk — to avoid confusion.
- 🔄 **Smart Formatting Logic:**
  - If the drive is already `ext4`, it skips formatting and proceeds.
  - If the drive is `NTFS` or `exFAT`, it warns you and gives you the choice to format to `ext4` for best server performance, or keep the existing format (automatically installing `ntfs-3g` / `exfat-fuse`).
- 🏷️ **Custom Drive Naming:** Asks you to name the drive (e.g. `Movies`, `Backup`) and creates a clean folder in `/mnt/<name>` — no ugly UUID paths.
- 📌 **Persistent Mounting:** Extracts the drive's UUID and adds it to `/etc/fstab` so it survives reboots. Re-running on the same drive is safe and skips re-mounting.
- 🐳 **Expandable LXC Architecture:**
  - **First Run:** Creates a lightweight, unprivileged Debian 12 LXC container (`Samba-NAS`), installs Samba, and bind-mounts your drive inside it.
  - **Subsequent Runs:** If you add a 2nd or 3rd hard drive, the script detects the existing `Samba-NAS` container and injects the new drive into it automatically — no new containers created!
- 🌐 **Network Configuration:** Supports both DHCP and Static IP. For Static IP, the script auto-detects your gateway and suggests a valid IP example so you can't type something wrong.
- 🔐 **Security Choice:** Prompts you to secure your share with a password (using your system username automatically) or create a public guest share.
- 🖥️ **Multi-Platform Access Instructions:** The final output shows how to connect from **Windows**, **Mac**, and **Linux**.
- 🛡️ **Proper UID Mapping:** Automatically handles UID/GID mapping (`101000:101000`) for `ext4` drives inside unprivileged containers for correct write permissions.
</details>

**🚀 Run Command:**
*(Run from your Proxmox Host as a regular sudo user)*
```bash
sudo curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/nas_setup.sh | sudo bash
```

---

### 3️⃣ Core Services Setup (`setup_core.sh`)

A powerful script to instantly spin up a dedicated unprivileged LXC container tailored for essential home server services using Docker.

<details>
<summary><b>✨ View Features</b></summary>

- 🚀 **Automated LXC Creation:** Deploys a Debian 12 unprivileged container optimized for Docker (`nesting=1`, `keyctl=1`).
- ⚙️ **Performance Tuned:** Automatically assigns 2 CPU Cores and 1GB RAM (with 0 swap) for smooth operation of multiple services.
- 🕒 **Timezone Sync:** Syncs the container timezone with the Proxmox host to ensure logs and scheduled updates are accurate.
- 🔐 **Secure Setup:** Prompts for a custom root password for the container to ensure secure local access.
- 🐳 **Instant Docker Stack:** Pre-configures and launches a complete Docker compose stack with:
  - **Nginx Proxy Manager** (Reverse proxy & SSL)
  - **Homepage** (Beautiful custom dashboard)
  - **Portainer** (Visual Docker management)
  - **Vaultwarden** (Self-hosted password manager)
  - **Watchtower** (Automated container updates)
</details>

**🚀 Run Command:**
*(Run from your Proxmox Host as a regular sudo user)*
```bash
sudo curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/setup_core.sh | sudo bash
```

---

## 🤝 Contributing

Feel free to fork this repository, submit Pull Requests, or open Issues to suggest improvements or new scripts!

## 📜 License

Distributed under the MIT License. See `LICENSE` for more information.

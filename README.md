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

### 🌐 Network access (local-first)

**By default, every service stays on your LAN** — each script assigns a static IP and you open it from your home network (e.g. `http://192.168.1.10:8080`). Nothing is published to the internet automatically.

| Access method | Scripts | Use when |
|---------------|---------|----------|
| **LAN only** (default) | All setup scripts | Normal home use — NAS, media, DNS, Vaultwarden, etc. |
| **Domain + HTTPS** (optional) | `setup_dashboard.sh` (AutoExposer) | You own a domain and want `*.yourdomain.com` via NPM + Cloudflare |
| **Cloudflare Tunnel** (optional) | `setup_n8n.sh` | You need **n8n** (and Evolution API) reachable from outside; leave the token blank to keep it local too |

> **Typical setup:** keep Core, NAS, Media, DNS, and Sync on the LAN; expose only **n8n** through a Cloudflare Tunnel if you need remote automation.

**LXC shell access:** scripts do not ask for a container root password. Manage containers from the Proxmox host with `pct enter <CTID>` (requires host `root` / `sudo`).

---

## 🎛️ Interactive Unified Menu (`menu.sh`)

The easiest and recommended way to use this repository is via the new interactive menu. It automatically discovers all available setup scripts and lets you run them with a single keystroke, without having to copy-paste multiple commands.

**🚀 Run Command:**
*(Run from your Proxmox Host as a regular sudo user)*
```bash
sudo curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/menu.sh | sudo bash
```

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
- 🔐 **Secure Setup:** Prompts for a **Vaultwarden admin password** (hashed with Argon2id). LXC root is not set via prompt — use `pct enter <CTID>` from the Proxmox host for console access.
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

### 4️⃣ AutoExposer Platform (`setup_dashboard.sh`)

A highly advanced Python-based infrastructure management platform. It automatically discovers all your LXC and Docker services (using Traefik-like labels), generates Wildcard SSL certificates via Cloudflare, exposes them via Nginx Proxy Manager, and builds a beautiful Homepage dashboard — entirely hands-free.

> **Note:** **Optional** — skip this if everything stays on the LAN (e.g. you only use a Cloudflare Tunnel for n8n). Run it **after** deploying core services **if** you have a domain and want HTTPS URLs for local services.

<details>
<summary><b>✨ View Features</b></summary>

- 🧠 **Hybrid Auto-Discovery:** Scans Proxmox for LXCs and reads Docker container labels (`autoexposer.enable=true`) to detect ports, icons, and categories.
- 🔒 **Zero-Touch SSL:** Connects securely to NPM API and generates Cloudflare wildcard certificates (`*.yourdomain.com`).
- 🔄 **State Management:** Uses SQLite to track exactly what has been exposed, preventing duplicates and enabling safe, idempotent re-runs.
- 🎨 **Homepage Auto-Builder:** Automatically groups your discovered services and writes a clean, formatted `services.yaml` to your Homepage container.
- 🧪 **Dry-Run Mode:** Test your setup safely without modifying NPM or Homepage.
- 🐍 **Modern Python Architecture:** Built using `typer`, `rich`, `pydantic`, and `httpx` for extreme speed and reliability.
</details>

**🚀 Run Command:**
*(Run from your Proxmox Host as a regular sudo user)*
```bash
sudo curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/setup_dashboard.sh | sudo bash
```

---

### 5️⃣ AdGuard Home + Unbound DNS (`adguard_unbound.sh`)

A highly optimized script that deploys **AdGuard Home** (Network-wide ad blocker) and **Unbound** (Recursive DNS resolver) inside a dedicated LXC container to provide fast, private, and ad-free internet for your entire home.

<details>
<summary><b>✨ View Features</b></summary>

- 🛡️ **AdGuard Home:** Beautiful, powerful network-wide ad and tracker blocking.
- 🌍 **Unbound DNS:** Acts as your own root DNS resolver. No more sending DNS queries to Google or Cloudflare; Unbound queries the root servers directly for maximum privacy.
- ⚡ **Optimized Caching:** Pre-configured Unbound settings for aggressive caching (improving DNS speed) and DNSSEC validation (improving security).
- 🧩 **Perfect Integration:** Automatically sets Unbound as the upstream DNS server for AdGuard Home.
- 🛑 **Port Conflict Fixes:** Intelligently disables `systemd-resolved` to prevent port 53 conflicts during setup.
- 🌐 **Static IP Enforcement:** Ensures your DNS server has a static IP address, which is mandatory for reliable network operation.
- 🔐 **LXC Native:** Runs directly on Debian 12 LXC (no Docker overhead) for maximum performance and minimum latency.
</details>

**🚀 Run Command:**
*(Run from your Proxmox Host as a regular sudo user)*
```bash
sudo curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/adguard_unbound.sh | sudo bash
```

---

### 6️⃣ Proxmox Sync & Backup LXC (`sync_setup.sh`)

A powerful script to instantly spin up a dedicated unprivileged LXC container tailored for secure file synchronization and note backups using **Syncthing** and **CouchDB** (perfect for Obsidian LiveSync).

<details>
<summary><b>✨ View Features</b></summary>

- 🚀 **Automated LXC Creation:** Deploys a Debian 12 unprivileged container.
- 💾 **External Storage Support:** Optionally formats and mounts a dedicated external drive directly into the LXC for sync data.
- 🔄 **Syncthing:** Pre-configured for local file synchronization.
- 📝 **CouchDB / Obsidian LiveSync:** Pre-installed CouchDB with full CORS configuration ready for Obsidian LiveSync.
- 🔐 **Secure Setup:** Prompts for a custom admin password for CouchDB and Syncthing.
</details>

**🚀 Run Command:**
*(Run from your Proxmox Host as root or using sudo)*
```bash
sudo curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/sync_setup.sh | sudo bash
```

---

### 7️⃣ Proxmox Backup Server (`setup_pbs.sh`)

A highly optimized script to deploy **Proxmox Backup Server (PBS)** natively inside a Debian 12 LXC container for comprehensive, incremental backups of your entire Proxmox environment.

<details>
<summary><b>✨ View Features</b></summary>

- 🚀 **Automated LXC Creation:** Deploys a Debian 12 unprivileged container tailored for PBS.
- 💾 **Datastore Handling:** Includes specific guidance and preparation for mounting external SMB/NFS datastores securely via Proxmox Host bind-mounts.
- 🛡️ **Resource Optimized:** Configures optimal CPU and RAM settings for backup server deduplication workloads.
- 🔐 **Automated Auth:** Generates and sets up the PBS `root@pam` password securely during installation.
</details>

**🚀 Run Command:**
*(Run from your Proxmox Host as a regular sudo user)*
```bash
sudo curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/setup_pbs.sh | sudo bash
```

---

### 8️⃣ Hermes AI Agent Stack (`setup_hermes.sh`)

An advanced, security-hardened script that deploys the **NousResearch Hermes AI Agent** inside an optimized LXC container. It integrates a local Proxmox MCP server to safely manage VMs and containers, featuring strict least-privilege security boundaries and auto-exposure.

<details>
<summary><b>✨ View Features & Security Architecture</b></summary>

- 🛡️ **Least-Privilege API Access (Role-Based):** Unlike standard setups that require Proxmox `root@pam` access, this script automatically creates a restricted role (`HermesMinimal`) with minimal permissions (`VM.Audit`, `VM.PowerMgmt`, `VM.Console`, `Datastore.Audit`, `Sys.Audit`). Even if the AI agent is compromised, your main Proxmox host and databases remain completely safe from destructive commands.
- 🐳 **Docker Socket Proxy Security:** Mounts a secure proxy (`docker-proxy`) inside the container instead of passing the raw `/var/run/docker.sock`. This restricts the AI agent to safe read/write endpoints and isolates the host system.
- 📡 **ARP-Level Network Scan:** Uses `arping` on the Proxmox host for 100% reliable IP conflict detection, ensuring your chosen static IP is completely free even if target hosts block ping requests.
- 🔗 **Proxmox MCP Server:** Sets up a dedicated Model Context Protocol (MCP) server that acts as a translator between Hermes' natural language queries and the Proxmox API.
- 🌐 **AutoExposer Integration:** Automatically detects your Cloudflare domain via `auto_exposer` configuration, configures Nginx Proxy Manager / Homepage dashboard, and hides internal IP/ports on success.
- 📦 **No Bloat:** Excludes auxiliary services like Portainer Agent and Watchtower to keep CPU/RAM usage inside the LXC at absolute minimum.
- 🔄 **Idempotent Rollback:** Automatically reverts only newly created Proxmox tokens or users if the installation fails mid-way, leaving pre-existing credentials untouched.

#### 📊 Setup Workflow

```mermaid
flowchart TD
    Start([Run Script]) --> Preflight[1. Pre-flight Checks]
    Preflight -->|Root & PVE Host| AutoDetect[2. Auto-Detect Plan]
    AutoDetect -->|Suggest ID, Storage, IP| ConflictCheck{3. Check IP Conflict}
    ConflictCheck -->|arping scan| FreeIP{IP Busy?}
    FreeIP -->|Yes| UserIP[Prompt Alternative IP]
    FreeIP -->|No| ConfirmPlan[Confirm Setup Plan]
    UserIP --> ConfirmPlan
    ConfirmPlan --> Secrets[4. Input Secrets: Telegram & OpenAI]
    
    subgraph Host_Sec [Host Security Boundary]
        Secrets --> CreateRole[Create HermesMinimal Role]
        CreateRole --> CreateUser[Create hermes-agent@pve User]
        CreateUser --> GenToken[Generate API Token]
    end
    
    subgraph LXC_Setup [Container Sandbox]
        Secrets --> LXC[5. Create LXC Container]
        LXC --> InstallDocker[6. Install Docker & Compose]
        InstallDocker --> SetupMCP[7. Setup Proxmox MCP Server]
        GenToken --> SetupMCP
        SetupMCP --> ConfigFiles[8. Write configs & docker-compose]
        ConfigFiles --> StartServices[9. Start Stack]
    end
    
    StartServices --> HealthCheck{11. Health Check}
    HealthCheck -->|Healthy| AutoExposer[12. AutoExposer Sync]
    AutoExposer --> ShowSummary[Show Domain URL & Summary]
    ShowSummary --> End([Success])
```
</details>

**🚀 Run Command:**
*(Run from your Proxmox Host as a regular sudo user)*
```bash
sudo curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/setup_hermes.sh | sudo bash
```

---

## 🤝 Contributing

Feel free to fork this repository, submit Pull Requests, or open Issues to suggest improvements or new scripts!

## 📜 License

Distributed under the MIT License. See `LICENSE` for more information.

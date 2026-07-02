<div align="center">
  <h1>🚀 Ultimate Home Server Suite</h1>
  <p><b>The definitive, automated infrastructure management system for Proxmox and LXC.</b></p>
  
  <img src="https://img.shields.io/badge/Proxmox-8.x_|_9.x-orange.svg?style=for-the-badge&logo=proxmox" />
  <img src="https://img.shields.io/badge/Status-Optimized-emerald?style=for-the-badge&logo=gnu-bash&logoColor=white" />
  <img src="https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge" />
</div>

---

## 📖 Overview

This suite is designed to take your home lab from zero to production-ready in minutes. It intelligently handles everything from base node optimizations to complex media and automation stacks.

By using the **Unified Intelligent Menu**, you ensure that your system always utilizes the latest security patches and script optimizations automatically.

---

## 🎛️ Intelligent Control Center

The **Unified Menu** is now the primary entry point for all operations. It automatically synchronizes with our central repository to provide you with the most up-to-date deployment scripts available.

### ⚡ Quick Launch Command
Run this command on your Proxmox Host to access the full suite of deployment tools:

```bash
# For root user (Default on Proxmox VE):
curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/menu.sh | bash

# For non-root users:
curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/menu.sh | sudo bash
```

## 📊 Telemetry and Analytics

To help improve the scripts and understand usage, a lightweight anonymous telemetry ping is sent when you run the setup scripts. It collects non-identifiable hardware stats (OS, CPU, RAM, Disk) and generates a random local UUID. No personal data, IPs, or secrets are collected.

---

## 🛠️ Included Solutions (Managed via Menu)

The Unified Menu gives you one-click access to these high-performance stacks:

| Stack | Script | Services |
|---|---|---|
| 🛡️ **Proxmox Base Setup** | `setup.sh` | Smart repo fixes & system optimizations |
| 📂 **Samba NAS** | `nas_setup.sh` | High-availability expandable network storage |
| 📦 **Core Infrastructure** | `setup_core.sh` | NPM, Vaultwarden, Homepage, Portainer |
| 🌐 **AdGuard + Unbound** | `adguard_unbound.sh` | Network-wide ad-blocking & private DNS |
| 🤖 **n8n Automation** | `setup_n8n.sh` | n8n + Evolution API + PostgreSQL |
| 🧠 **Hermes AI Stack** | `setup_hermes.sh` | Autonomous AI agent deployment |
| 🔄 **Sync & Backup** | `sync_setup.sh` | CoSync (Obsidian), Syncthing, Kopia |
| 🔗 **AutoExposer** | `setup_dashboard.sh` | Auto DNS/SSL/Reverse-proxy via NPM + Cloudflare |

---

## 💎 Features

*   **[i] Smart Hardware Profiling:** Scripts automatically analyze your CPU, RAM, and Disk to apply specific hardware optimizations.
*   **🔄 Auto-Sync:** Every time you launch the menu, it checks for updates and pulls the latest features from GitHub.
*   **🛡️ Local-First Security:** All services are configured for local network security by default.
*   **🚀 Zero-Config UI:** Modern dashboards are automatically provisioned and ready for use.
*   **🔗 AutoExposer Integration:** All stacks include pre-configured labels — run AutoExposer once to get domains, SSL, and Homepage entries for every service automatically.
*   **📸 Kopia Backup:** Incremental, deduplicated, encrypted snapshots of your data — accessible via a clean web UI at `kopia.<your-domain>`.

---
<div align="center">
  <p><i>Building the future of self-hosted infrastructure.</i></p>
</div>

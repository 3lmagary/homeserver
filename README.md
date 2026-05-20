<div align="center">
  <h1>🚀 Ultimate Home Server Setup</h1>
  <p><b>A modern, automated approach to bootstrapping Proxmox VE and Home Server LXC containers.</b></p>
  
  [![Proxmox VE](https://img.shields.io/badge/Proxmox-8.x-orange.svg?style=for-the-badge&logo=proxmox)](#)
  [![Shell Script](https://img.shields.io/badge/Shell_Script-121011?style=for-the-badge&logo=gnu-bash&logoColor=white)](#)
  [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](#)
</div>

---

## 📖 Overview

Setting up a home lab from scratch can be repetitive and tedious. This repository provides **production-ready bash scripts** designed to rapidly configure Proxmox nodes and LXC containers with industry best practices, saving you time and ensuring a secure baseline.

## 🛠️ Available Scripts

### 1️⃣ Proxmox Base Setup (`setup.sh`)
A foundational script for fresh Proxmox VE nodes (or Debian/Ubuntu hosts). It handles repository management, creates a secure non-root user, and sets up beautiful terminal aesthetics.

<details>
<summary><b>✨ View Features</b></summary>

- 🔄 **Safe Updates:** Full system update & upgrade.
- 📦 **Essential Tools:** Installs `curl`, `git`, `htop`, `sudo`, `zsh`, and network tools.
- 👤 **Secure User:** Replaces root usage with a proper interactive sudo user.
- 🛠 **Repo Fixes:** Disables the paid Enterprise repo & adds the free No-Subscription repo.
- 🎨 **Aesthetics:** Configures `Zsh` with the cross-shell `Starship` prompt (`~ ❯`).
</details>

**🚀 Run Command:**
```bash
bash <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/setup.sh)
```


## 🤝 Contributing
Feel free to fork this repository, submit Pull Requests, or open Issues to suggest improvements or new scripts!

## 📜 License
Distributed under the MIT License. See `LICENSE` for more information.

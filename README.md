# Proxmox & Home Server Setup Script

A streamlined, automated setup script designed to quickly bootstrap a fresh Proxmox environment or a standard Debian/Ubuntu-based Home Server.

## Overview

When setting up a new Proxmox node or a Linux home server, there are several repetitive tasks required to get a secure and optimized baseline environment. This script automates that process, transitioning you from a bare-bones root environment into a customized, secure, and ready-to-use workspace.

## Features

- **Proxmox Repository Management**: Automatically disables the enterprise repository (which requires a paid subscription) and enables the free `pve-no-subscription` repository.
- **System Updates**: Performs a full system update and upgrade (`apt-get update && apt-get dist-upgrade`).
- **Essential Packages**: Installs necessary server tools (`curl`, `git`, `zsh`, `sudo`, `htop`, `wget`, `unzip`, `neofetch`).
- **User Management**: Prompts to create a new non-root user and automatically grants them `sudo` privileges.
- **Docker Integration**: Installs Docker and Docker Compose, adding the new user to the `docker` group so you don't need `sudo` for container management.
- **Terminal Customization**: 
  - Changes the default shell from `bash` to `zsh`.
  - Installs **Oh My Zsh**.
  - Configures the **Agnoster** theme for a sleek look.
  - Installs essential productivity plugins: `zsh-autosuggestions` and `zsh-syntax-highlighting`.

## Prerequisites

- A fresh installation of Proxmox VE (tested on v8 / Bookworm) or a Debian/Ubuntu-based system.
- Root access to the server.

## Installation & Usage

You can run this script using a single command directly from your terminal:

```bash
bash <(curl -s https://raw.githubusercontent.com/USERNAME/REPO_NAME/main/setup.sh)
```

Alternatively, you can clone the repository or download the script manually:

```bash
# 1. Download the script
wget https://raw.githubusercontent.com/USERNAME/REPO_NAME/main/setup.sh

# 2. Make it executable
chmod +x setup.sh

# 3. Run the script as root
./setup.sh
```

## Post-Installation

Once the script completes, log in as your newly created user:

```bash
su - <your-new-username>
```

Your environment will now be equipped with Zsh, Docker, and a fully updated system ready for your home lab projects.

## License

This project is open-source and available under the [MIT License](LICENSE). Feel free to fork and modify it to suit your specific needs.

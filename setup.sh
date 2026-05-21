#!/bin/bash

set -e

# =============================
# Proxmox Safe Base Setup
# =============================

GREEN="\033[0;32m"
BLUE="\033[0;34m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=============================="
echo " Proxmox Setup Script"
echo -e "==============================${NC}"

# 1) DISABLE ENTERPRISE REPO SAFELY
echo -e "${GREEN}[1/6] Cleaning Proxmox repos...${NC}"
# Disable all Proxmox & Ceph Enterprise repos dynamically in all apt sources
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    if [ -f "$f" ]; then
        sed -i 's/^[[:space:]]*deb[[:space:]]*https:\/\/enterprise.proxmox.com/# &/' "$f"
    fi
done

# Get Debian codename dynamically
source /etc/os-release
CODENAME=${VERSION_CODENAME:-bookworm}

# Ensure no duplicate repo injection
grep -q "pve-no-subscription" /etc/apt/sources.list || \
echo "deb http://download.proxmox.com/debian/pve $CODENAME pve-no-subscription" >> /etc/apt/sources.list

# 2) SYSTEM UPDATE (SAFE ONLY)
echo -e "${GREEN}[2/6] Updating system safely...${NC}"
apt update
apt full-upgrade -y

# 3) ESSENTIAL TOOLS ONLY
echo -e "${GREEN}[3/6] Installing base tools...${NC}"
apt install -y \
curl \
wget \
git \
sudo \
htop \
iotop \
iftop \
nano \
net-tools \
ca-certificates \
gnupg \
lsb-release

# 4) CREATE USER
echo -e "${GREEN}[4/6] Creating user...${NC}"
read -p "Enter username: " USERNAME

if id "$USERNAME" &>/dev/null; then
    echo -e "${RED}User exists, skipping...${NC}"
else
    adduser "$USERNAME"
    usermod -aG sudo "$USERNAME"
    echo -e "${GREEN}User created.${NC}"
fi

# 5) TERMINAL BEAUTIFICATION (Zsh + Starship)
echo -e "${GREEN}[5/6] Installing Zsh & Starship Prompt (~ ❯)...${NC}"
apt install -y zsh
chsh -s $(which zsh) "$USERNAME" || true
chsh -s $(which zsh) root || true

# Install Starship cross-shell prompt
curl -sS https://starship.rs/install.sh | sh -s -- -y

# Configure Starship for the new user and root
echo 'eval "$(starship init zsh)"' >> /home/$USERNAME/.zshrc
chown $USERNAME:$USERNAME /home/$USERNAME/.zshrc
echo 'eval "$(starship init zsh)"' >> /root/.zshrc

# 6) CLEANUP
echo -e "${GREEN}[6/6] Cleaning system...${NC}"
apt autoremove -y
apt clean

echo -e "${BLUE}=============================="
echo -e " SETUP COMPLETE SAFE MODE"
echo -e "==============================${NC}"

echo "Login with: su - $USERNAME"
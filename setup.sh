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
if [ -f /etc/apt/sources.list ]; then
    sed -i 's/^\s*deb\s*https\?:\/\/enterprise\.proxmox\.com/# &/' /etc/apt/sources.list 2>/dev/null || true
fi

for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    if [ -f "$f" ] && grep -q "enterprise.proxmox.com" "$f"; then
        mv "$f" "${f}.disabled"
        echo -e "${GREEN}Disabled enterprise repo file: $f${NC}"
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

EXISTING_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "ceph" && ($7 == "/bin/bash" || $7 == "/usr/bin/bash" || $7 == "/bin/zsh" || $7 == "/usr/bin/zsh" || $7 == "/bin/sh") {print $1}' /etc/passwd | head -n 1)

if [ -n "$EXISTING_USER" ]; then
    echo -e "${YELLOW}Existing user found: '$EXISTING_USER'. Skipping new user creation.${NC}"
    USERNAME="$EXISTING_USER"
else
    while true; do
        read -p "Enter username (e.g. john): " USERNAME

        if [ -z "$USERNAME" ]; then
            echo -e "${RED}Username cannot be empty. Please try again.${NC}"
            continue
        fi

        if id "$USERNAME" &>/dev/null; then
            echo -e "${YELLOW}User '$USERNAME' already exists, skipping creation...${NC}"
            break
        fi

        set +e
        adduser "$USERNAME"
        ADD_STATUS=$?
        set -e

        if [ $ADD_STATUS -eq 0 ]; then
            usermod -aG sudo "$USERNAME"
            echo -e "${GREEN}User created successfully.${NC}"
            break
        else
            echo -e "${RED}Error: Invalid username format (e.g., starts with a number).${NC}"
            read -p "Do you want to force adding this username anyway? (y/N): " FORCE
            if [[ "$FORCE" =~ ^[Yy]$ ]]; then
                set +e
                adduser --allow-bad-names "$USERNAME"
                FORCE_STATUS=$?
                set -e

                if [ $FORCE_STATUS -eq 0 ]; then
                    usermod -aG sudo "$USERNAME"
                    echo -e "${GREEN}User created successfully with --allow-bad-names.${NC}"
                    break
                else
                    echo -e "${RED}Still failed to create user. Please try a different name.${NC}"
                fi
            else
                echo -e "${YELLOW}Please enter a standard username (starts with a letter, lowercase only, no spaces).${NC}"
            fi
        fi
    done
fi

# 5) TERMINAL BEAUTIFICATION (Oh My Zsh + Plugins)
echo -e "${GREEN}[5/7] Installing Zsh, Oh My Zsh & Plugins...${NC}"
apt install -y zsh git

install_omz() {
    local TARGET_USER=$1
    local HOME_DIR=$2

    # Install Oh My Zsh unattended
    su - "$TARGET_USER" -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
    
    # Clone plugins
    su - "$TARGET_USER" -c "git clone https://github.com/zsh-users/zsh-autosuggestions $HOME_DIR/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
    su - "$TARGET_USER" -c "git clone https://github.com/zsh-users/zsh-syntax-highlighting.git $HOME_DIR/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"

    # Enable plugins and set theme to robbyrussell
    su - "$TARGET_USER" -c "sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' $HOME_DIR/.zshrc"
    
    # Ensure robbyrussell is set in case of a rerun
    su - "$TARGET_USER" -c "sed -i 's/ZSH_THEME=\"powerlevel10k\/powerlevel10k\"/ZSH_THEME=\"robbyrussell\"/' $HOME_DIR/.zshrc"
    su - "$TARGET_USER" -c "sed -i 's/ZSH_THEME=\"agnoster\"/ZSH_THEME=\"robbyrussell\"/' $HOME_DIR/.zshrc"
}

# Run installation for created user and root
install_omz "$USERNAME" "/home/$USERNAME"
install_omz "root" "/root"

chsh -s $(which zsh) "$USERNAME" || true
chsh -s $(which zsh) root || true

# 6) AUTO-LOGIN SETUP
echo -e "${GREEN}[6/7] Configuring auto-login for $USERNAME...${NC}"
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat <<EOF > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I \$TERM
EOF
systemctl daemon-reload || true

# 7) CLEANUP
echo -e "${GREEN}[7/7] Cleaning system...${NC}"
apt autoremove -y
apt clean

echo -e "${BLUE}=============================="
echo -e " SETUP COMPLETE SAFE MODE"
echo -e "==============================${NC}"

echo "User '$USERNAME' will automatically log in on the local console."
echo "If using SSH, login with: su - $USERNAME"
#!/bin/bash
set -Eeuo pipefail

# ==========================================
# Ultimate Home Server Setup - Unified Menu
# ==========================================

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run this menu script as root or using sudo.${NC}"
  exit 1
fi

# Handle execution via curl pipeline or locally
set +u # Temporarily disable unbound variable check
if [ -z "${BASH_SOURCE[0]}" ] || [ "${BASH_SOURCE[0]}" == "bash" ] || [ "${BASH_SOURCE[0]}" == "sh" ]; then
    set -u
    echo -e "${GREEN}Downloading/Updating Home Server repository...${NC}"
    if ! command -v git &> /dev/null; then
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y git >/dev/null 2>&1 || true
    fi
    
    if [ -d "/opt/homeserver" ]; then
        cd /opt/homeserver
        git pull origin main -q || true
    else
        git clone https://github.com/3lmagary/homeserver.git /opt/homeserver -q
        cd /opt/homeserver
    fi
else
    set -u
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$SCRIPT_DIR"
fi

# Define known scripts and their descriptive titles
declare -A SCRIPT_TITLES
SCRIPT_TITLES["setup.sh"]="Proxmox Base Node Setup"
SCRIPT_TITLES["nas_setup.sh"]="Expandable Samba NAS Setup"
SCRIPT_TITLES["adguard_unbound.sh"]="AdGuard Home + Unbound DNS Setup"
SCRIPT_TITLES["setup_core.sh"]="Core Services Setup (NPM, Vaultwarden, Homepage, Portainer)"
SCRIPT_TITLES["setup_dashboard.sh"]="AutoExposer DNS/SSL/Homepage Sync (Python)"
SCRIPT_TITLES["setup_immich.sh"]="Immich Photo Server Stack"
SCRIPT_TITLES["setup_media.sh"]="Jellyfin Media Stack (Jellyfin, Radarr, Sonarr, qBittorrent, Jellyseerr)"
SCRIPT_TITLES["setup_n8n.sh"]="n8n Automation + Evolution API Stack"
SCRIPT_TITLES["sync_setup.sh"]="Syncthing & CouchDB Setup (Obsidian LiveSync)"
SCRIPT_TITLES["setup_vpn_torrent.sh"]="VPN-secured qBittorrent (Gluetun + qBittorrent)"
SCRIPT_TITLES["setup_pbs.sh"]="Proxmox Backup Server (Native LXC)"

# Dynamically scan for available scripts
AVAILABLE_SCRIPTS=()
for key in "setup.sh" "nas_setup.sh" "adguard_unbound.sh" "setup_core.sh" "setup_dashboard.sh" "setup_immich.sh" "setup_media.sh" "setup_n8n.sh" "sync_setup.sh" "setup_vpn_torrent.sh" "setup_pbs.sh"; do
    if [ -f "$key" ]; then
        AVAILABLE_SCRIPTS+=("$key")
    fi
done

if [ ${#AVAILABLE_SCRIPTS[@]} -eq 0 ]; then
    echo -e "${RED}Error: No setup scripts found in the current directory ($SCRIPT_DIR).${NC}"
    exit 1
fi

show_menu() {
    clear
    echo -e "${BLUE}=============================================================="
    echo -e "         🚀 Ultimate Home Server Setup - Interactive Menu"
    echo -e "==============================================================${NC}"
    echo -e "Select one of the available scripts to execute:\n"
    
    local idx=1
    for script in "${AVAILABLE_SCRIPTS[@]}"; do
        local title="${SCRIPT_TITLES[$script]:-$script}"
        echo -e "  [${YELLOW}$idx${NC}] $title (${BLUE}$script${NC})"
        ((idx++))
    done
    
    echo -e "  [${RED}0${NC}] Exit Menu"
    echo -e "${BLUE}==============================================================${NC}"
}

while true; do
    show_menu
    read -p "Enter your choice: " CHOICE < /dev/tty
    
    if [ "$CHOICE" == "0" ]; then
        echo -e "\n${GREEN}Goodbye!${NC}"
        exit 0
    fi
    
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#AVAILABLE_SCRIPTS[@]}" ]; then
        echo -e "\n${RED}Invalid choice. Press Enter to try again...${NC}"
        read -r < /dev/tty
        continue
    fi
    
    SELECTED_SCRIPT="${AVAILABLE_SCRIPTS[$((CHOICE-1))]}"
    SELECTED_TITLE="${SCRIPT_TITLES[$SELECTED_SCRIPT]:-$SELECTED_SCRIPT}"
    
    echo -e "\n${GREEN}Starting: $SELECTED_TITLE...${NC}"
    echo -e "${YELLOW}--------------------------------------------------------------${NC}\n"
    
    # Run the script and preserve exit code
    set +e
    bash "./$SELECTED_SCRIPT"
    STATUS=$?
    set -e
    
    echo -e "\n${YELLOW}--------------------------------------------------------------${NC}"
    if [ $STATUS -eq 0 ]; then
        echo -e "${GREEN}✓ Execution completed successfully!${NC}"
    else
        echo -e "${RED}✗ Execution failed with status $STATUS.${NC}"
    fi
    echo -e "Press Enter to return to the menu..."
    read -r < /dev/tty
done

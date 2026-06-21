#!/bin/bash
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)
set -Eeuo pipefail

# ==========================================
# Core Services Setup (Docker LXC)
# ==========================================

# Note: Telegram integration was intentionally removed for simplicity and privacy.

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo -e "  Core Services Setup (Docker LXC)"
echo -e "==========================================${NC}"

# Ensure script is run as root (elevate if possible)
if [ "$EUID" -ne 0 ]; then
  if command -v sudo &>/dev/null; then
    echo -e "\033[1;33mThis script needs root privileges. Re-running with sudo...\033[0m"
    if [[ "$0" =~ ^(bash|sh|dash)$ || "$0" == "stdin" || -z "$0" ]]; then
       echo -e "\033[0;31mError: Piped script must be run as root or using: curl -s ... | sudo bash\033[0m"
       exit 1
    else
       exec sudo bash "$0" "$@"
    fi
  else
    echo -e "\033[0;31mError: Please run this script as root (sudo is not installed).\033[0m"
    exit 1
  fi
fi

# Check if already exists
LXC_NAME="Core-Services"
EXISTING_CTID=$(pct list 2>/dev/null | awk -v name="$LXC_NAME" '$3 == name {print $1}' || true)
if [ -n "$EXISTING_CTID" ]; then
    echo -e "${RED}Error: LXC '$LXC_NAME' already exists (ID: $EXISTING_CTID). Delete it first if you want to reinstall.${NC}"
    exit 1
fi

# Auto-Rollback Settings
ROLLBACK_REQUIRED=true
CTID=""

cleanup_on_exit() {
    local exit_code=$?
    if [ "$ROLLBACK_REQUIRED" = true ]; then
        echo -e "\n${RED}Error occurred during installation. Initiating auto-rollback...${NC}"
        if [ -n "${CTID:-}" ] && pct status "$CTID" &>/dev/null; then
            echo -e "${YELLOW}Stopping and destroying failed container $CTID ($LXC_NAME)...${NC}"
            pct stop "$CTID" &>/dev/null || true
            pct destroy "$CTID" &>/dev/null || true
            echo -e "${GREEN}Rollback complete. Container deleted.${NC}"
        fi
    fi
}

trap cleanup_on_exit EXIT ERR

echo -e "${GREEN}[1/4] Preparing LXC Container...${NC}"
pveam update >/dev/null 2>&1 || true
TEMPLATE_PATH=$(pveam available -section system | grep debian-12-standard | awk '{print $2}' | head -n 1)
if [ -z "$TEMPLATE_PATH" ]; then echo -e "${RED}Could not find Debian 12 template.${NC}"; exit 1; fi
if ! pveam list local | grep -q debian-12; then pveam download local "$TEMPLATE_PATH" >/dev/null 2>&1; fi
LOCAL_TEMPLATE=$(pveam list local | grep debian-12 | awk '{print $1}' | head -n 1)

GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
CIDR=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1 | cut -d/ -f2)
if [ -z "$CIDR" ]; then CIDR="24"; fi

echo -ne "\nScanning network to find a free static IP automatically..."
find_free_ip() {
    local gw="$1"
    local base_ip=$(echo "$gw" | cut -d. -f1-3)
    local assigned_ips
    assigned_ips=$(grep -r -o -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' /etc/pve/lxc/ /etc/pve/qemu-server/ 2>/dev/null | cut -d: -f2 | sort -u || true)
    local tmp_dir=$(mktemp -d)
    for i in {50..150}; do
        local test_ip="${base_ip}.${i}"
        if [ "$test_ip" = "$gw" ] || echo "$assigned_ips" | grep -q -w "$test_ip"; then
            continue
        fi
        ( ping -c 1 -W 1 "$test_ip" &>/dev/null && touch "${tmp_dir}/${i}" ) &
    done
    sleep 1.2
    local free_ip=""
    for i in {50..150}; do
        local test_ip="${base_ip}.${i}"
        if [ "$test_ip" = "$gw" ] || echo "$assigned_ips" | grep -q -w "$test_ip" || [ -f "${tmp_dir}/${i}" ]; then
            continue
        fi
        if ip neigh show | grep -q -w "$test_ip"; then
            continue
        fi
        free_ip="$test_ip"
        break
    done
    rm -rf "$tmp_dir"
    if [ -n "$free_ip" ]; then
        echo "$free_ip"
        return 0
    fi
    return 1
}

STATIC_IP=$(find_free_ip "$GW")
if [ -z "$STATIC_IP" ]; then
    echo -e "\n${RED}Error: Could not find any free IP address in the subnet automatically.${NC}"
    exit 1
fi
echo -e "Selected IP: ${YELLOW}$STATIC_IP${NC}"

echo -e "\n${YELLOW}Password Configuration for Vaultwarden:${NC}"
read -p "Do you want to auto-generate a secure Vaultwarden Admin password? (Y/n): " GEN_CHOICE < /dev/tty
GEN_CHOICE=${GEN_CHOICE:-"Y"}

if [[ "$GEN_CHOICE" =~ ^[Yy]$ ]]; then
    # Generate secure admin token
    VW_ADMIN_PASS=$(openssl rand -base64 32)
    echo -e "${GREEN}✓ Auto-generated Vaultwarden Admin Password: ${YELLOW}$VW_ADMIN_PASS${NC}"
    echo "Vaultwarden Admin Password: $VW_ADMIN_PASS" >> /root/generated-passwords.txt
    chmod 600 /root/generated-passwords.txt
else
    read -sp "Enter custom password for Vaultwarden admin: " VW_ADMIN_PASS < /dev/tty; echo
    if [ -z "$VW_ADMIN_PASS" ]; then echo -e "${RED}Vaultwarden password cannot be empty.${NC}"; exit 1; fi
fi

read -p "Enter Disk Size in GB (default: 10): " DISK_SIZE < /dev/tty
if [ -z "$DISK_SIZE" ]; then DISK_SIZE="10"; fi
if ! [[ "$DISK_SIZE" =~ ^[0-9]+$ ]]; then echo -e "${RED}Disk size must be a number.${NC}"; exit 1; fi

NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

# Get Next ID
CTID=$(pvesh get /cluster/nextid)

echo "Creating Core LXC $CTID on $TARGET_STORAGE with ${DISK_SIZE}GB disk..."
pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --rootfs "$TARGET_STORAGE:$DISK_SIZE" --hostname "$LXC_NAME" \
    --net0 "$NET_CONFIG" --unprivileged 1 --features nesting=1,keyctl=1
pct set $CTID -onboot 1 --timezone host
pct start $CTID

echo "Waiting for network..."
sleep 15

echo -e "${GREEN}[2/4] Installing Docker and Utilities...${NC}"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl ca-certificates argon2"
pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"

echo -e "${GREEN}[3/4] Writing Docker Compose config...${NC}"
pct exec $CTID -- mkdir -p /opt/core

# Generate Argon2id hash inside the container and retrieve it
echo -e "${GREEN}Generating Vaultwarden admin password hash...${NC}"
SALT=$(openssl rand -hex 8)
VW_ADMIN_HASH=$(pct exec $CTID -- env VW_PASS="$VW_ADMIN_PASS" VW_SALT="$SALT" bash -c 'echo -n "$VW_PASS" | argon2 "$VW_SALT" -e -id -k 65540 -t 3 -p 4 | grep -o "\$argon2id\$.*" | tr -d "\r"')

if [ -z "$VW_ADMIN_HASH" ]; then
    echo -e "${RED}Error: Failed to generate Vaultwarden admin password hash.${NC}"
    exit 1
fi

# Write the raw hash directly to a file to avoid Docker Compose interpolation warnings ($ variables)
pct exec $CTID -- mkdir -p /opt/core/vaultwarden
pct exec $CTID -- bash -c "echo -n '$VW_ADMIN_HASH' > /opt/core/vaultwarden/admin_token.txt"

# Write docker-compose.yml
cat << EOF | pct exec $CTID -- tee /opt/core/docker-compose.yml >/dev/null
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - '80:80'
      - '81:81'
      - '443:443'
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt

  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    ports:
      - '8080:80'
    environment:
      - ADMIN_TOKEN_FILE=/data/admin_token.txt
    volumes:
      - ./vaultwarden:/data

  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    ports:
      - '3000:3000'
    environment:
      - HOMEPAGE_ALLOWED_HOSTS=*
    volumes:
      - ./homepage:/app/config
      - /var/run/docker.sock:/var/run/docker.sock:ro

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - '9000:9000'
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./portainer:/data

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    environment:
      - WATCHTOWER_LABEL_ENABLE=true
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_SCHEDULE=0 0 12 * * *
      - DOCKER_API_VERSION=1.40
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF

echo -e "${GREEN}[4/4] Starting services...${NC}"
pct exec $CTID -- bash -c "cd /opt/core && docker compose up -d"

# Deployment successful - disable rollback
ROLLBACK_REQUIRED=false
trap - EXIT ERR

echo -e "\n${BLUE}================================================================"
echo -e " ✅ CORE SETUP COMPLETE! TAKE A SCREENSHOT OF THIS BOX "
echo -e "================================================================${NC}"
echo -e "${GREEN}▶ Nginx Proxy Manager (Reverse Proxy) ${NC}"
echo -e "   - URL:      ${YELLOW}http://${STATIC_IP}:81${NC}"
echo -e "   - Default:  ${YELLOW}admin@example.com${NC} / ${YELLOW}changeme${NC}"
echo -e ""
echo -e "${GREEN}▶ Vaultwarden (Passwords) ${NC}"
echo -e "   - URL:      ${YELLOW}http://${STATIC_IP}:8080${NC}"
echo -e "   - Admin:    ${YELLOW}http://${STATIC_IP}:8080/admin${NC}"
echo -e "   - Password: ${YELLOW}${VW_ADMIN_PASS}${NC}"
if [[ "$GEN_CHOICE" =~ ^[Yy]$ ]]; then
echo -e "   - Note:     ${GREEN}Saved to /root/generated-passwords.txt on host${NC}"
fi
echo -e ""
echo -e "${GREEN}▶ Homepage (Dashboard) ${NC}"
echo -e "   - URL:      ${YELLOW}http://${STATIC_IP}:3000${NC}"
echo -e ""
echo -e "${GREEN}▶ Portainer (Container Manager) ${NC}"
echo -e "   - URL:      ${YELLOW}http://${STATIC_IP}:9000${NC}"
echo -e ""
echo -e "${GREEN}▶ Proxmox LXC Server (SSH/Console) ${NC}"
echo -e "   - IP:       ${YELLOW}${STATIC_IP}${NC}"
echo -e "   - User:     ${YELLOW}root${NC}"
echo -e "================================================================"
echo -e "${RED}⚠️  IMPORTANT SECURITY WARNING:${NC}"
echo -e "You MUST change the default Nginx Proxy Manager credentials immediately"
echo -e "on your first visit to secure your setup!"
echo -e "================================================================"
echo -e "\n${YELLOW}Note: Watchtower only updates containers that have the label 'com.centurylinklabs.watchtower.enable=true'${NC}"
echo -e "\n\033[1;32mInfo:\033[0m Telegram integration was intentionally removed for simplicity and privacy."
echo -e ""
echo -e "\033[1;33mNote:\033[0m LXC root password prompt has been removed for better automation."
echo -e "To access this container's shell, run: \033[0;32mpct enter $CTID\033[0m from your Proxmox host."

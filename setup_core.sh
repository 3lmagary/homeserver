#!/bin/bash
set -e

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo -e "  Core Services Setup (Docker LXC)"
echo -e "==========================================${NC}"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root.${NC}"
  exit 1
fi

# Check if already exists
LXC_NAME="Core-Services"
EXISTING_CTID=$(pct list | awk -v name="$LXC_NAME" '$3 == name {print $1}')
if [ -n "$EXISTING_CTID" ]; then
    echo -e "${RED}Error: LXC '$LXC_NAME' already exists (ID: $EXISTING_CTID). Delete it first if you want to reinstall.${NC}"
    exit 1
fi

CTID=$(pvesh get /cluster/nextid)

echo -e "${GREEN}[1/4] Preparing LXC Container...${NC}"
pveam update >/dev/null 2>&1
TEMPLATE_PATH=$(pveam available -section system | grep debian-12-standard | awk '{print $2}' | head -n 1)
if [ -z "$TEMPLATE_PATH" ]; then echo -e "${RED}Could not find Debian 12 template.${NC}"; exit 1; fi
if ! pveam list local | grep -q debian-12; then pveam download local "$TEMPLATE_PATH" >/dev/null 2>&1; fi
LOCAL_TEMPLATE=$(pveam list local | grep debian-12 | awk '{print $1}' | head -n 1)

GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
CIDR=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1 | cut -d/ -f2)
if [ -z "$CIDR" ]; then CIDR="24"; fi
EXAMPLE_IP=$(echo "$GW" | awk -F. '{print $1"."$2"."$3".10"}')

echo -e "\nDetected Gateway: $GW"
read -p "Enter STATIC IP for Core Services (e.g. $EXAMPLE_IP): " STATIC_IP < /dev/tty
if [ -z "$STATIC_IP" ]; then echo -e "${RED}Static IP is required. Exiting.${NC}"; exit 1; fi

read -sp "Enter a password for Vaultwarden admin: " VW_ADMIN_PASS < /dev/tty; echo
if [ -z "$VW_ADMIN_PASS" ]; then echo -e "${RED}Vaultwarden password cannot be empty.${NC}"; exit 1; fi

read -p "Enter Disk Size in GB (default: 10): " DISK_SIZE < /dev/tty
if [ -z "$DISK_SIZE" ]; then DISK_SIZE="10"; fi
if ! [[ "$DISK_SIZE" =~ ^[0-9]+$ ]]; then echo -e "${RED}Disk size must be a number.${NC}"; exit 1; fi

if [[ "$ENABLE_TG" =~ ^[Yy]$ ]]; then
    read -p "Enter Telegram Bot Token: " TG_TOKEN < /dev/tty
    if [ -z "$TG_TOKEN" ]; then echo -e "${RED}Telegram Bot Token cannot be empty.${NC}"; exit 1; fi
    read -p "Enter Telegram Chat ID: " TG_CHAT_ID < /dev/tty
    if [ -z "$TG_CHAT_ID" ]; then echo -e "${RED}Telegram Chat ID cannot be empty.${NC}"; exit 1; fi
fi

NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

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
SALT=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
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
$(if [[ "$ENABLE_TG" =~ ^[Yy]$ ]]; then
echo "      - WATCHTOWER_NOTIFICATIONS=shoutrrr"
echo "      - WATCHTOWER_NOTIFICATION_URL=telegram://$TG_TOKEN@telegram/?channels=$TG_CHAT_ID"
fi)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF

echo -e "${GREEN}[4/4] Starting services...${NC}"
pct exec $CTID -- bash -c "cd /opt/core && docker compose up -d"

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
echo -e "================================================================${NC}"
echo -e "\n${YELLOW}Note: Watchtower only updates containers that have the label 'com.centurylinklabs.watchtower.enable=true'${NC}"

echo -e ""
echo -e "\033[1;33mNote:\033[0m LXC root password prompt has been removed for better automation."
echo -e "To access this container's shell, run: \033[0;32mpct enter \$CTID\033[0m from your Proxmox host."

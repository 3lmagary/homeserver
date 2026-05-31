#!/bin/bash
set -e

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo -e "  Immich Photo Server (Docker LXC)"
echo -e "==========================================${NC}"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root.${NC}"
  exit 1
fi

LXC_NAME="Immich"
EXISTING_CTID=$(pct list | awk -v name="$LXC_NAME" '$3 == name {print $1}')
if [ -n "$EXISTING_CTID" ]; then
    echo -e "${RED}Error: LXC '$LXC_NAME' already exists (ID: $EXISTING_CTID).${NC}"
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
EXAMPLE_IP=$(echo "$GW" | awk -F. '{print $1"."$2"."$3".30"}')

echo -e "\nDetected Gateway: $GW"
read -p "Enter STATIC IP for Immich (e.g. $EXAMPLE_IP): " STATIC_IP < /dev/tty
if [ -z "$STATIC_IP" ]; then echo -e "${RED}Static IP is required. Exiting.${NC}"; exit 1; fi

read -p "Enter Disk Size in GB (default: 20): " DISK_SIZE < /dev/tty
if [ -z "$DISK_SIZE" ]; then DISK_SIZE="20"; fi

if [[ "$ENABLE_TG" =~ ^[Yy]$ ]]; then
    read -p "Enter Telegram Bot Token: " TG_TOKEN < /dev/tty
    read -p "Enter Telegram Chat ID: " TG_CHAT_ID < /dev/tty
fi

NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

# Immich needs at least 2GB RAM for ML models
echo "Creating Immich LXC $CTID on $TARGET_STORAGE with ${DISK_SIZE}GB disk (2GB RAM for AI models)..."
pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --rootfs "$TARGET_STORAGE:$DISK_SIZE" --hostname "$LXC_NAME" \
    --memory 2048 --swap 512
pct set $CTID -onboot 1
pct start $CTID

echo "Waiting for network..."
sleep 15

echo -e "${GREEN}[2/4] Installing Docker...${NC}"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl wget ca-certificates"
pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"

echo -e "${GREEN}[3/4] Downloading Immich config & configuring...${NC}"
pct exec $CTID -- mkdir -p /opt/immich/library

pct exec $CTID -- bash -c "cd /opt/immich && \
    wget -qO docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml && \
    wget -qO .env https://github.com/immich-app/immich/releases/latest/download/example.env"

# Generate secure DB password on host and inject it into the container's .env
DB_PASS=$(openssl rand -hex 16)
# Use printf to avoid issues with special characters in sed replacement
pct exec $CTID -- bash -c "sed -i 's|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|' /opt/immich/.env"
# Must be an absolute path - relative paths break Immich
pct exec $CTID -- bash -c "sed -i 's|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=/opt/immich/library|' /opt/immich/.env"

# Append Portainer Agent and Watchtower to Immich docker-compose.yml
cat << EOF | pct exec $CTID -- bash -c "cat >> /opt/immich/docker-compose.yml"

  portainer-agent:
    image: portainer/agent:latest
    container_name: portainer_agent
    restart: unless-stopped
    ports:
      - '9001:9001'
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes

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

echo -e "${GREEN}[4/4] Starting Immich (this takes 3-5 minutes)...${NC}"
pct exec $CTID -- bash -c "cd /opt/immich && docker compose up -d"

echo -e "\n${BLUE}=========================================="
echo -e " ✅ Immich Deployed!"
echo -e "==========================================${NC}"
echo -e "Access Immich at: ${YELLOW}http://${STATIC_IP}:2283${NC}"
echo -e "\n${YELLOW}Note: The first startup takes 3-5 minutes."
echo -e "Immich needs to initialize the database and download AI models.${NC}"
echo -e "${YELLOW}Photos are stored at: /opt/immich/library (inside the container)${NC}"

echo -e ""
echo -e "\033[1;33mNote:\033[0m LXC root password prompt has been removed for better automation."
echo -e "To access this container's shell, run: \033[0;32mpct enter \$CTID\033[0m from your Proxmox host."

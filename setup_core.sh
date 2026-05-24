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

read -sp "Enter a password for the Container root user: " CT_ROOT_PASS < /dev/tty; echo
if [ -z "$CT_ROOT_PASS" ]; then echo -e "${RED}Container password cannot be empty.${NC}"; exit 1; fi

NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

echo "Creating Core LXC $CTID on $TARGET_STORAGE with ${DISK_SIZE}GB disk..."
pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --rootfs "$TARGET_STORAGE:$DISK_SIZE" --hostname "$LXC_NAME" \
    --memory 1024 --swap 0 --cores 2 --password "$CT_ROOT_PASS" \
    --net0 "$NET_CONFIG" --unprivileged 1 --features nesting=1,keyctl=1
pct set $CTID -onboot 1 --timezone host
pct start $CTID

echo "Waiting for network..."
sleep 15

echo -e "${GREEN}[2/4] Installing Docker...${NC}"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl ca-certificates"
pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"

echo -e "${GREEN}[3/4] Writing Docker Compose config...${NC}"
pct exec $CTID -- mkdir -p /opt/core

# Write .env file with secrets
pct exec $CTID -- bash -c "cat > /opt/core/.env << EOF
VW_ADMIN_TOKEN=$VW_ADMIN_PASS
EOF"

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
      - WEBSOCKET_ENABLED=true
      - ADMIN_TOKEN=\${VW_ADMIN_TOKEN}
      - I_REALLY_WANT_VOLATILE_STORAGE=true
    volumes:
      - ./vaultwarden:/vw-data

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
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
      - DOCKER_API_VERSION=1.40
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF

echo -e "${GREEN}[4/4] Starting services...${NC}"
pct exec $CTID -- bash -c "cd /opt/core && docker compose up -d"

echo -e "\n${BLUE}=========================================="
echo -e " ✅ Core Services Ready! (الخدمات جاهزة)"
echo -e "==========================================${NC}"
echo -e "Nginx Proxy Manager: ${YELLOW}http://${STATIC_IP}:81${NC}  (admin@example.com / changeme)"
echo -e "Homepage:            ${YELLOW}http://${STATIC_IP}:3000${NC}"
echo -e "Portainer:           ${YELLOW}http://${STATIC_IP}:9000${NC}"
echo -e "Vaultwarden:         ${YELLOW}http://${STATIC_IP}:8080${NC}"
echo -e "Vaultwarden Admin:   ${YELLOW}http://${STATIC_IP}:8080/admin${NC}"
echo -e "\n${YELLOW}Note: Watchtower only updates containers that have the label 'com.centurylinklabs.watchtower.enable=true'${NC}"

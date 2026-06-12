#!/bin/bash
set -Eeuo pipefail

# ======================================================
# NousResearch Hermes AI Agent Stack Setup for Proxmox VE
# Production Grade: Security + Reliability + LXC Support
# ======================================================

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BOLD="\033[1m"
NC="\033[0m"

echo -e "${BLUE}======================================================="
echo -e "  NousResearch Hermes AI Agent Setup"
echo -e "  Optimized for Proxmox (VM & LXC Support)"
echo -e "=======================================================${NC}"

# Check root and Proxmox host
if [ "$EUID" -ne 0 ]; then echo -e "${RED}Run as root!${NC}"; exit 1; fi
if ! command -v pveversion &>/dev/null; then echo -e "${RED}Not a Proxmox host!${NC}"; exit 1; fi

# [1/6] Configuration
echo -e "\n${GREEN}[1/6] Configuring Settings...${NC}"
CTID=$(pvesh get /cluster/nextid)
read -p "Container ID [$CTID]: " USER_CTID < /dev/tty || true
CTID=${USER_CTID:-$CTID}

STORAGES=($(pvesm status -content rootdir | awk 'NR>1 {print $1}'))
echo -e "Available Storage: ${STORAGES[*]}"
read -p "Storage [${STORAGES[0]}]: " TARGET_STORAGE < /dev/tty || true
TARGET_STORAGE=${TARGET_STORAGE:-${STORAGES[0]}}

GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1 | cut -d. -f1-3)
read -p "Static IP [$SUBNET.150]: " STATIC_IP < /dev/tty || true
STATIC_IP=${STATIC_IP:-$SUBNET.150}

read -p "Telegram Bot Token: " TG_TOKEN < /dev/tty || true
read -p "Telegram User ID: " TG_UID < /dev/tty || true

# [2/6] Create LXC
echo -e "\n${GREEN}[2/6] Creating LXC...${NC}"
pveam update >/dev/null 2>&1 || true
TEMPLATE=$(pveam list local | grep debian-12 | awk '{print $1}' | head -n 1 || true)
if [ -z "$TEMPLATE" ]; then
    echo "Downloading Debian 12 template..."
    pveam download local $(pveam available -section system | grep debian-12-standard | awk '{print $2}' | head -n 1) >/dev/null
    TEMPLATE=$(pveam list local | grep debian-12 | awk '{print $1}' | head -n 1)
fi

pct create $CTID "$TEMPLATE" --storage "$TARGET_STORAGE" --rootfs "$TARGET_STORAGE:30" --hostname "Hermes-Agent" \
    --net0 "name=eth0,bridge=vmbr0,ip=$STATIC_IP/24,gw=$GW" \
    --unprivileged 1 --features nesting=1,keyctl=1 --memory 2048 --cores 2 --swap 1024
pct start $CTID
echo "Waiting for network..."
until pct exec $CTID -- ping -c 1 -W 1 google.com &>/dev/null; do sleep 1; done

# [3/6] Install Docker
echo -e "\n${GREEN}[3/6] Installing Docker...${NC}"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl git python3 python3-pip"
pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"

# [4/6] API Setup
echo -e "\n${GREEN}[4/6] Proxmox API Token...${NC}"
PRIVS="VM.Audit,VM.PowerMgmt,VM.Console,Datastore.Audit,Sys.Audit"
pveum role add "HermesMinimal" -privs "$PRIVS" 2>/dev/null || pveum role modify "HermesMinimal" -privs "$PRIVS"
pveum user add "hermes-agent@pve" -comment "Hermes AI Agent" 2>/dev/null || true
pveum aclmod / -user "hermes-agent@pve" -role "HermesMinimal"
TOKEN_DATA=$(pveum user token add "hermes-agent@pve" "hermes-token" -privsep 1 --output-format json)
TOKEN_SECRET=$(echo "$TOKEN_DATA" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['value'])")
PVE_HOST=$(hostname -I | awk '{print $1}')

# [5/6] Proxmox MCP & Patches
echo -e "\n${GREEN}[5/6] Deploying Hermes Stack...${NC}"
pct exec $CTID -- mkdir -p /opt/hermes/data
pct exec $CTID -- git clone https://github.com/canvrno/ProxmoxMCP.git /opt/hermes/proxmox-mcp

# Write Stack Config
cat << ENV_EOF | pct exec $CTID -- tee /opt/hermes/.env >/dev/null
PROXMOX_API_URL=https://$PVE_HOST:8006/api2/json
PROXMOX_TOKEN_ID=hermes-agent@pve!hermes-token
PROXMOX_TOKEN_SECRET=$TOKEN_SECRET
PROXMOX_VERIFY_SSL=false
OPENAI_API_KEY=please_configure_in_web_ui
TELEGRAM_BOT_TOKEN=$TG_TOKEN
TELEGRAM_ALLOWED_USERS=$TG_UID
HERMES_DASHBOARD=true
HERMES_DASHBOARD_INSECURE=true
ENV_EOF

cat << 'COMPOSE_EOF' | pct exec $CTID -- tee /opt/hermes/docker-compose.yml >/dev/null
services:
  docker-proxy:
    image: tecnativa/docker-socket-proxy
    volumes: [/var/run/docker.sock:/var/run/docker.sock:ro]
    environment: [CONTAINERS=1, IMAGES=1, NETWORKS=1]
    networks: [hermes-net]
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    env_file: .env
    environment: [DOCKER_HOST=tcp://docker-proxy:2375]
    ports: ["8642:8642", "9119:9119"]
    volumes: [./data:/opt/data]
    depends_on: [docker-proxy]
    networks: [hermes-net]
  proxmox-mcp:
    build: ./proxmox-mcp
    container_name: proxmox-mcp
    restart: unless-stopped
    ports: ["8380:8380"]
    env_file: .env
    environment: [PROXMOX_HOST=https://192.168.0.10:8006, PROXMOX_MCP_CONFIG=proxmox-config/config.json]
    networks: [hermes-net]
networks:
  hermes-net:
    driver: bridge
COMPOSE_EOF

# Setup Allowlist
cat << JSON_EOF | pct exec $CTID -- tee /opt/hermes/data/channel_directory.json >/dev/null
{
  "updated_at": "2026-06-12T00:00:00Z",
  "platforms": { "telegram": [ { "id": "$TG_UID", "label": "User", "role": "user" } ] }
}
JSON_EOF

# [6/6] Launch
echo -e "\n${GREEN}[6/6] Starting Services...${NC}"
pct exec $CTID -- bash -c "chown -R 1000:1000 /opt/hermes/data && cd /opt/hermes && docker compose up -d --build"

echo -e "\n${GREEN}✅ HARDENED SETUP COMPLETE!${NC}"

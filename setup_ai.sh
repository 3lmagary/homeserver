#!/bin/bash
set -e

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo -e "  AI & Automation Stack (Docker LXC)"
echo -e "==========================================${NC}"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root.${NC}"
  exit 1
fi

LXC_NAME="AI-Stack"
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
EXAMPLE_IP=$(echo "$GW" | awk -F. '{print $1"."$2"."$3".40"}')

echo -e "\nDetected Gateway: $GW"
read -p "Enter STATIC IP for AI Stack (e.g. $EXAMPLE_IP): " STATIC_IP < /dev/tty
if [ -z "$STATIC_IP" ]; then echo -e "${RED}Static IP is required. Exiting.${NC}"; exit 1; fi

# Collect credentials upfront
read -p "Enter n8n admin username: " N8N_USER < /dev/tty
read -sp "Enter n8n admin password: " N8N_PASS < /dev/tty; echo
read -sp "Enter Evolution API authentication key (any strong string): " EVO_API_KEY < /dev/tty; echo
read -sp "Enter Flowise username password: " FLOWISE_PASS < /dev/tty; echo

echo -e "\n${YELLOW}Do you have a Cloudflare Tunnel token? (for n8n external access)${NC}"
read -p "Cloudflare Tunnel Token (leave blank to skip): " CF_TOKEN < /dev/tty

NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

echo "Creating AI LXC $CTID on $TARGET_STORAGE..."
pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --hostname "$LXC_NAME" \
    --net0 "$NET_CONFIG" --unprivileged 1 --features nesting=1,keyctl=1
pct set $CTID -onboot 1
pct start $CTID

echo "Waiting for network..."
sleep 15

echo -e "${GREEN}[2/4] Installing Docker...${NC}"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl ca-certificates"
pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"

echo -e "${GREEN}[3/4] Writing Docker Compose config...${NC}"
pct exec $CTID -- mkdir -p /opt/ai

# Generate a secure DB password for Evolution API
EVO_DB_PASS=$(openssl rand -hex 16)

# Write .env file so secrets are not in the compose file
pct exec $CTID -- bash -c "cat > /opt/ai/.env << EOF
N8N_BASIC_AUTH_USER=${N8N_USER}
N8N_BASIC_AUTH_PASSWORD=${N8N_PASS}
EVO_API_KEY=${EVO_API_KEY}
EVO_DB_PASS=${EVO_DB_PASS}
FLOWISE_PASSWORD=${FLOWISE_PASS}
CF_TOKEN=${CF_TOKEN}
EOF"

# Build cloudflared service conditionally
CF_SERVICE=""
if [ -n "$CF_TOKEN" ]; then
CF_SERVICE="
  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=\${CF_TOKEN}"
fi

cat << EOF | pct exec $CTID -- tee /opt/ai/docker-compose.yml >/dev/null
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n
    restart: unless-stopped
    ports:
      - 5678:5678
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=\${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=\${N8N_BASIC_AUTH_PASSWORD}
      - N8N_HOST=${STATIC_IP}
      - WEBHOOK_URL=http://${STATIC_IP}:5678
      - TZ=Africa/Cairo
    volumes:
      - ./n8n_data:/home/node/.n8n

  postgres-evo:
    image: postgres:15
    restart: unless-stopped
    environment:
      - POSTGRES_USER=evolution
      - POSTGRES_PASSWORD=\${EVO_DB_PASS}
      - POSTGRES_DB=evolution
    volumes:
      - ./evo_postgres:/var/lib/postgresql/data

  redis-evo:
    image: redis:7-alpine
    restart: unless-stopped
    volumes:
      - ./evo_redis:/data

  evolution-api:
    image: atendai/evolution-api:latest
    restart: unless-stopped
    ports:
      - 8080:8080
    depends_on:
      - postgres-evo
      - redis-evo
    environment:
      - SERVER_URL=http://${STATIC_IP}:8080
      - DOCKER_ENV=true
      - DATABASE_ENABLED=true
      - DATABASE_CONNECTION_URI=postgresql://evolution:\${EVO_DB_PASS}@postgres-evo:5432/evolution
      - CACHE_REDIS_ENABLED=true
      - CACHE_REDIS_URI=redis://redis-evo:6379/6
      - AUTHENTICATION_TYPE=apikey
      - AUTHENTICATION_API_KEY=\${EVO_API_KEY}
    volumes:
      - ./evo_data:/evolution/instances

  flowise:
    image: flowiseai/flowise
    restart: unless-stopped
    ports:
      - 3000:3000
    environment:
      - FLOWISE_USERNAME=admin
      - FLOWISE_PASSWORD=\${FLOWISE_PASSWORD}
    volumes:
      - ./flowise_data:/root/.flowise
${CF_SERVICE}
EOF

echo -e "${GREEN}[4/4] Starting services...${NC}"
pct exec $CTID -- bash -c "cd /opt/ai && docker compose up -d"

echo -e "\n${BLUE}=========================================="
echo -e " ✅ AI & Automation Stack Ready!"
echo -e "==========================================${NC}"
echo -e "n8n:           ${YELLOW}http://${STATIC_IP}:5678${NC}  (login: $N8N_USER)"
echo -e "Evolution API: ${YELLOW}http://${STATIC_IP}:8080${NC}"
echo -e "Flowise:       ${YELLOW}http://${STATIC_IP}:3000${NC}  (login: admin)"
if [ -n "$CF_TOKEN" ]; then
    echo -e "\n${GREEN}Cloudflare Tunnel is active. Your services are accessible externally via your tunnel.${NC}"
fi
echo -e "\n${YELLOW}Credentials are stored in: /opt/ai/.env (inside the container)${NC}"

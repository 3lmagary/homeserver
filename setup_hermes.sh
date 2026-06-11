#!/bin/bash
set -Eeuo pipefail

# ==========================================
# NousResearch Hermes AI Agent Stack Setup
# ==========================================

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo -e "  NousResearch Hermes AI Agent Setup"
echo -e "==========================================${NC}"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root.${NC}"
  exit 1
fi

# Check if already exists
LXC_NAME="Hermes-Agent"
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
EXAMPLE_IP=$(echo "$GW" | awk -F. '{print $1"."$2"."$3".35"}')

echo -e "\nDetected Gateway: $GW"
read -p "Enter STATIC IP for the LXC Container (e.g. $EXAMPLE_IP): " STATIC_IP < /dev/tty
if [ -z "$STATIC_IP" ]; then echo -e "${RED}Static IP is required. Exiting.${NC}"; exit 1; fi

echo -e "\n${YELLOW}Hermes AI Agent Configuration:${NC}"
echo "You can leave these blank and configure them later or use a local LLM (Ollama)."
read -p "Enter Gemini API Key (recommended): " GEMINI_API_KEY < /dev/tty
read -p "Enter OpenAI API Key: " OPENAI_API_KEY < /dev/tty
read -p "Enter OpenRouter API Key: " OPENROUTER_API_KEY < /dev/tty
read -p "Enter Ollama Host URL (e.g. http://192.168.1.50:11434, leave blank if none): " OLLAMA_HOST < /dev/tty

read -p "Enter Disk Size in GB (default: 30): " DISK_SIZE < /dev/tty
if [ -z "$DISK_SIZE" ]; then DISK_SIZE="30"; fi

NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

# Get Next ID
CTID=$(pvesh get /cluster/nextid)

echo "Creating Hermes LXC $CTID on $TARGET_STORAGE with ${DISK_SIZE}GB disk..."
pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --rootfs "$TARGET_STORAGE:$DISK_SIZE" --hostname "$LXC_NAME" \
    --net0 "$NET_CONFIG" --unprivileged 1 --features nesting=1,keyctl=1
pct set $CTID -onboot 1 --timezone host
pct start $CTID

echo "Waiting for network..."
sleep 15

echo -e "${GREEN}[2/4] Installing Docker...${NC}"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl ca-certificates"
pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"

echo -e "${GREEN}[3/4] Writing Docker Compose config...${NC}"
pct exec $CTID -- mkdir -p /opt/hermes

# Write .env file
pct exec $CTID -- bash -c "cat > /opt/hermes/.env << 'ENVEOF'
GEMINI_API_KEY=$GEMINI_API_KEY
OPENAI_API_KEY=$OPENAI_API_KEY
OPENROUTER_API_KEY=$OPENROUTER_API_KEY
OLLAMA_HOST=$OLLAMA_HOST
HERMES_UID=1000
HERMES_GID=1000
API_SERVER_HOST=0.0.0.0
GATEWAY_HEALTH_URL=http://hermes:8642
ENVEOF"

# Write docker-compose.yml
cat << EOF | pct exec $CTID -- tee /opt/hermes/docker-compose.yml >/dev/null
services:
  hermes:
    image: ghcr.io/nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    command: gateway run
    ports:
      - "8642:8642"
    volumes:
      - ./data:/opt/data
    env_file:
      - .env

  dashboard:
    image: ghcr.io/nousresearch/hermes-agent:latest
    container_name: hermes-dashboard
    restart: unless-stopped
    command: dashboard --host 0.0.0.0 --insecure
    ports:
      - "9119:9119"
    volumes:
      - ./data:/opt/data
    env_file:
      - .env
    depends_on:
      - hermes

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
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF

echo -e "${GREEN}[4/4] Starting services...${NC}"
pct exec $CTID -- bash -c "mkdir -p /opt/hermes/data && chown -R 1000:1000 /opt/hermes/data"
pct exec $CTID -- bash -c "cd /opt/hermes && docker compose up -d"

# Deployment successful - disable rollback
ROLLBACK_REQUIRED=false
trap - EXIT ERR

echo -e "\n${BLUE}================================================================"
echo -e " ✅ SETUP COMPLETE! TAKE A SCREENSHOT OF THIS BOX "
echo -e "================================================================${NC}"
echo -e "${GREEN}▶ Hermes AI Dashboard (Web UI) ${NC}"
echo -e "   - URL:      ${YELLOW}http://${STATIC_IP}:9119${NC}"
echo -e ""
echo -e "${GREEN}▶ Hermes AI Gateway (API) ${NC}"
echo -e "   - URL:      ${YELLOW}http://${STATIC_IP}:8642${NC}"
echo -e ""
echo -e "${GREEN}▶ Proxmox LXC Server (SSH/Console) ${NC}"
echo -e "   - IP:       ${YELLOW}${STATIC_IP}${NC}"
echo -e "   - User:     ${YELLOW}root${NC}"
echo -e "================================================================"
echo -e "${YELLOW}Note: You can run the setup wizard interactively inside the container if needed:${NC}"
echo -e "   ${GREEN}pct enter $CTID${NC}"
echo -e "   ${GREEN}docker compose exec -it hermes hermes setup${NC}"
echo -e ""
echo -e "\033[1;33mNote:\033[0m LXC root password prompt has been removed for better automation."
echo -e "To access this container's shell, run: \033[0;32mpct enter $CTID\033[0m from your Proxmox host."
echo -e ""

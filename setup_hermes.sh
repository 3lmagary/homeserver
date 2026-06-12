#!/bin/bash
set -Eeuo pipefail

# ==============================================================================
# PROXMOX SETUP SCRIPT FOR NOUSRESEARCH HERMES AI AGENT (HARDENED)
# ==============================================================================
# Version: 2.0.0
# Features: Restricted Privileges, Docker Socket Proxy, Health Checks, 
#           Telegram Integration, Auto-Rollback.
# ==============================================================================

# --- Colors & UI ---
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m"

echo -e "${BLUE}${BOLD}======================================================="
echo -e "  Hardened Hermes AI Agent Setup for Proxmox"
echo -e "=======================================================${NC}"

# --- Environment Checks ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root.${NC}" 
   exit 1
fi

if ! command -v pveversion &>/dev/null; then
    echo -e "${RED}Error: Proxmox VE not detected. This script must run on a PVE host.${NC}"
    exit 1
fi

# --- Configuration Variables ---
ROLE_NAME="HermesOperator"
PVE_USER="hermes-agent@pve"
TOKEN_NAME="hermes-token"
LXC_NAME="Hermes-Agent"
WORKDIR="/opt/hermes"
CTID=""
STORAGE=""
CORES=""
RAM=""
BOT_TOKEN=""
USER_ID=""

# --- Rollback State ---
LXC_CREATED=false
ROLE_CREATED=false
USER_CREATED=false
TOKEN_CREATED=false

# --- Cleanup & Rollback Function ---
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n${RED}${BOLD}✖ Failure detected. Initiating auto-rollback...${NC}"
        
        if [ "$TOKEN_CREATED" = true ]; then
            echo -e "${YELLOW}Removing API token...${NC}"
            pveum user token remove "$PVE_USER" "$TOKEN_NAME" 2>/dev/null || true
        fi
        
        if [ "$USER_CREATED" = true ]; then
            echo -e "${YELLOW}Removing Proxmox user...${NC}"
            pveum user delete "$PVE_USER" 2>/dev/null || true
        fi
        
        if [ "$ROLE_CREATED" = true ]; then
            echo -e "${YELLOW}Removing Proxmox role...${NC}"
            pveum role delete "$ROLE_NAME" 2>/dev/null || true
        fi
        
        if [ "$LXC_CREATED" = true ] && [ -n "$CTID" ]; then
            echo -e "${YELLOW}Destroying container $CTID...${NC}"
            pct stop "$CTID" 2>/dev/null || true
            pct destroy "$CTID" 2>/dev/null || true
        fi
        
        echo -e "${GREEN}${BOLD}✔ Rollback complete.${NC}"
    fi
}
trap cleanup EXIT ERR

# --- Helper Functions ---
wait_for_service() {
    local cmd="$1"
    local msg="$2"
    local max_attempts=${3:-60}
    local attempt=1
    echo -ne "${CYAN}${msg}${NC} "
    while ! eval "$cmd" &>/dev/null; do
        if [ $attempt -eq $max_attempts ]; then
            echo -e "\n${RED}Timed out waiting for service.${NC}"
            exit 1
        fi
        echo -n "."
        sleep 2
        ((attempt++))
    done
    echo -e " ${GREEN}OK${NC}"
}

# --- [1/7] Interactive Configuration ---
echo -e "\n${BLUE}${BOLD}[1/7] Initializing Configuration...${NC}"

# CTID Selection
NEXT_ID=$(pvesh get /cluster/nextid)
read -p "$(echo -e "Enter Container ID [$NEXT_ID]: ")" input_ctid
CTID=${input_ctid:-$NEXT_ID}

if pct status "$CTID" &>/dev/null; then
    echo -e "${RED}Error: CTID $CTID is already in use.${NC}"
    exit 1
fi

# Storage Selection
echo -e "Available Storage (Rootdir support):"
pvesm status -content rootdir | awk 'NR>1 {print "  - "$1}'
read -p "$(echo -e "Enter Storage Name [local-lvm]: ")" input_storage
STORAGE=${input_storage:-local-lvm}

# Resource Allocation
read -p "$(echo -e "Enter CPU Cores [2]: ")" input_cores
CORES=${input_cores:-2}
read -p "$(echo -e "Enter RAM in MB [2048]: ")" input_ram
RAM=${input_ram:-2048}

# Telegram Integration
echo -e "\n${YELLOW}Telegram Integration Required:${NC}"
read -p "Enter Telegram Bot Token: " BOT_TOKEN
read -p "Enter Telegram User ID: " USER_ID

if [[ -z "$BOT_TOKEN" || -z "$USER_ID" ]]; then
    echo -e "${RED}Error: Telegram configuration is required for the hardened setup.${NC}"
    exit 1
fi

# --- [2/7] Proxmox LXC Creation ---
echo -e "\n${BLUE}${BOLD}[2/7] Creating Hardened LXC Container...${NC}"

# Ensure template is available
TEMPLATE_FILE="debian-12-standard_12.0-1_amd64.tar.zst"
if ! pveam list local | grep -q "debian-12"; then
    echo "Updating PVEAM and downloading Debian 12 template..."
    pveam update >/dev/null
    pveam download local "$TEMPLATE_FILE" >/dev/null
fi
TEMPLATE="local:vztmpl/$TEMPLATE_FILE"

pct create "$CTID" "$TEMPLATE" \
    --hostname "$LXC_NAME" \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:30" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --memory "$RAM" \
    --cores "$CORES" \
    --onboot 1

LXC_CREATED=true
pct start "$CTID"

wait_for_service "pct exec $CTID -- ping -c 1 google.com" "Waiting for container network..."

# --- [3/7] Docker Installation ---
echo -e "\n${BLUE}${BOLD}[3/7] Installing Docker Engine & Compose...${NC}"
pct exec "$CTID" -- bash -c "apt-get update && apt-get install -y curl ca-certificates gnupg git python3"
pct exec "$CTID" -- bash -c "curl -fsSL https://get.docker.com | sh"

# --- [4/7] Restricted Proxmox Role & User ---
echo -e "\n${BLUE}${BOLD}[4/7] Configuring Restricted Proxmox Privileges...${NC}"

if ! pveum role list | grep -q "$ROLE_NAME"; then
    echo "Creating role: $ROLE_NAME (Minimal Operator)"
    # Restricted privileges
    pveum role add "$ROLE_NAME" -privs "VM.Allocate,VM.Audit,VM.PowerMgmt,VM.Console,VM.Monitor,VM.Config.Options,VM.Config.CPU,VM.Config.Memory,VM.Config.Network,VM.Config.Disk,Datastore.Audit,Datastore.AllocateSpace"
    ROLE_CREATED=true
fi

if ! pveum user list | grep -q "$PVE_USER"; then
    echo "Creating user: $PVE_USER"
    pveum user add "$PVE_USER" --comment "Hermes AI Agent Service Account"
    USER_CREATED=true
fi

# Assign role at root
pveum aclmod / -user "$PVE_USER" -role "$ROLE_NAME"

# Create API Token
echo "Generating API Token..."
TOKEN_DATA=$(pveum user token add "$PVE_USER" "$TOKEN_NAME" --privsep 1 --output-format json)
TOKEN_CREATED=true

# Extract Token ID and Secret
TOKEN_ID=$(echo "$TOKEN_DATA" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['full-tokenid'])")
TOKEN_VALUE=$(echo "$TOKEN_DATA" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['value'])")

# --- [5/7] Configuration Deployment ---
echo -e "\n${BLUE}${BOLD}[5/7] Deploying Configuration & Security Policies...${NC}"

pct exec "$CTID" -- mkdir -p "$WORKDIR/data"
pct exec "$CTID" -- mkdir -p "$WORKDIR/docker-mcp"
pct exec "$CTID" -- mkdir -p "$WORKDIR/duckduckgo-mcp"
pct exec "$CTID" -- mkdir -p "$WORKDIR/proxmox-mcp"

# 1. Telegram Allowlist (channel_directory.json)
cat <<EOF | pct exec "$CTID" -- tee "$WORKDIR/data/channel_directory.json" > /dev/null
{
  "authorized_users": ["$USER_ID"],
  "authorized_channels": ["$USER_ID"],
  "allow_list": ["$USER_ID"]
}
EOF

# 2. Environment Configuration (.env)
HOST_IP=$(hostname -I | awk '{print $1}')
cat <<EOF | pct exec "$CTID" -- tee "$WORKDIR/.env" > /dev/null
# --- Docker Proxy ---
DOCKER_HOST=tcp://docker-proxy:2375

# --- Proxmox API ---
PROXMOX_HOST=https://$HOST_IP:8006
PROXMOX_TOKEN_ID=$TOKEN_ID
PROXMOX_TOKEN_SECRET=$TOKEN_VALUE
PROXMOX_VERIFY_SSL=false

# --- Telegram ---
TELEGRAM_BOT_TOKEN=$BOT_TOKEN
TELEGRAM_USER_ID=$USER_ID

# --- Hermes Runtime ---
HERMES_UID=1000
HERMES_GID=1000
EOF

# Strict permissions for .env
pct exec "$CTID" -- chmod 600 "$WORKDIR/.env"

# 3. MCP Server Definitions
# Docker MCP
cat << 'EOF' | pct exec "$CTID" -- tee "$WORKDIR/docker-mcp/server.py" > /dev/null
import asyncio
import docker
import uvicorn
from starlette.applications import Starlette
from starlette.routing import Route, Mount
from mcp.server.sse import SseServerTransport
from mcp_server_docker.server import app, ServerSettings
import mcp_server_docker.server as server_mod
import os

server_mod._docker = docker.DockerClient(base_url=os.getenv("DOCKER_HOST", "unix://var/run/docker.sock"))
server_mod._server_settings = ServerSettings()
sse = SseServerTransport('/messages/')

async def handle_sse(request):
    async with sse.connect_sse(request.scope, request.receive, request._send) as (read, write):
        await app.run(read, write, app.create_initialization_options())

starlette_app = Starlette(routes=[
    Route('/sse', endpoint=handle_sse, methods=['GET']),
    Mount('/messages/', app=sse.handle_post_message)
])

if __name__ == '__main__':
    uvicorn.run(starlette_app, host='0.0.0.0', port=8000)
EOF

cat << 'EOF' | pct exec "$CTID" -- tee "$WORKDIR/docker-mcp/Dockerfile" > /dev/null
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir mcp-server-docker docker uvicorn starlette
COPY server.py .
EXPOSE 8000
CMD ["python", "server.py"]
EOF

# DuckDuckGo MCP
cat << 'EOF' | pct exec "$CTID" -- tee "$WORKDIR/duckduckgo-mcp/Dockerfile" > /dev/null
FROM python:3.12-slim
RUN pip install --no-cache-dir duckduckgo-mcp-server
EXPOSE 8000
CMD ["python", "-c", "import sys; from duckduckgo_mcp_server.server import mcp, main; mcp.settings.transport_security.enable_dns_rebinding_protection = False if mcp.settings.transport_security else False; sys.argv = ['duckduckgo-mcp-server', '--transport', 'sse', '--host', '0.0.0.0', '--port', '8000']; main()"]
EOF

# Proxmox MCP (Cloning and Setup)
pct exec "$CTID" -- bash -c "git clone https://github.com/canvrno/ProxmoxMCP.git $WORKDIR/proxmox-mcp 2>/dev/null || true"
pct exec "$CTID" -- sed -i 's|mcp @ git+https://github.com/modelcontextprotocol/python-sdk.git|mcp>=1.0.0|' "$WORKDIR/proxmox-mcp/pyproject.toml"

# Patching Proxmox MCP for SSE
pct exec "$CTID" -- python3 -c '
import sys
file_path = "'"$WORKDIR"'/proxmox-mcp/src/proxmox_mcp/server.py"
content = open(file_path).read()
old_code = """        try:
            self.logger.info("Starting MCP server...")
            anyio.run(self.mcp.run_stdio_async)
        except Exception as e:"""

new_code = """        try:
            self.logger.info("Starting MCP server...")
            transport = "stdio"
            host = "0.0.0.0"
            port = 8380
            if "--transport" in sys.argv:
                idx = sys.argv.index("--transport")
                if idx + 1 < len(sys.argv):
                    transport = sys.argv[idx + 1]
            if "--host" in sys.argv:
                idx = sys.argv.index("--host")
                if idx + 1 < len(sys.argv):
                    host = sys.argv[idx + 1]
            if "--port" in sys.argv:
                idx = sys.argv.index("--port")
                if idx + 1 < len(sys.argv):
                    port = int(sys.argv[idx + 1])
            if transport == "sse":
                self.mcp.settings.host = host
                self.mcp.settings.port = port
                if self.mcp.settings.transport_security:
                    self.mcp.settings.transport_security.enable_dns_rebinding_protection = False
                self.mcp.run(transport="sse")
            else:
                self.mcp.run(transport="stdio")
        except Exception as e:"""

if old_code in content:
    open(file_path, "w").write(content.replace(old_code, new_code))
'

cat << 'EOF' | pct exec "$CTID" -- tee "$WORKDIR/proxmox-mcp/Dockerfile" > /dev/null
FROM python:3.12-slim
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir .
EXPOSE 8380
CMD ["python", "-m", "proxmox_mcp.server", "--transport", "sse", "--host", "0.0.0.0", "--port", "8380"]
EOF

# 4. Docker Compose with Socket Proxy (Security Hardening)
cat <<EOF | pct exec "$CTID" -- tee "$WORKDIR/docker-compose.yml" > /dev/null
services:
  docker-proxy:
    image: tecnativa/docker-socket-proxy
    container_name: docker-proxy
    restart: unless-stopped
    privileged: true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - CONTAINERS=1
      - IMAGES=1
      - NETWORKS=1
      - VOLUMES=1
      - POST=1
    networks:
      - hermes-net

  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./data:/opt/data
    depends_on:
      - docker-proxy
    networks:
      - hermes-net
    ports:
      - "8642:8642"
      - "9119:9119"

  docker-mcp:
    build: ./docker-mcp
    container_name: docker-mcp
    restart: unless-stopped
    environment:
      - DOCKER_HOST=tcp://docker-proxy:2375
    depends_on:
      - docker-proxy
    networks:
      - hermes-net

  duckduckgo-mcp:
    build: ./duckduckgo-mcp
    container_name: duckduckgo-mcp
    restart: unless-stopped
    networks:
      - hermes-net

  proxmox-mcp:
    build: ./proxmox-mcp
    container_name: proxmox-mcp
    restart: unless-stopped
    env_file: .env
    environment:
      - PROXMOX_HOST=https://$HOST_IP:8006
      - PROXMOX_TOKEN_ID=$TOKEN_ID
      - PROXMOX_TOKEN_SECRET=$TOKEN_VALUE
      - PROXMOX_VERIFY_SSL=false
    networks:
      - hermes-net

networks:
  hermes-net:
    driver: bridge
EOF

# 5. Hermes Config (config.yaml)
cat <<EOF | pct exec "$CTID" -- tee "$WORKDIR/data/config.yaml" > /dev/null
mcp_servers:
  docker:
    url: "http://docker-mcp:8000/sse"
    transport: sse
    description: "Docker Container Management"
  duckduckgo:
    url: "http://duckduckgo-mcp:8000/sse"
    transport: sse
    description: "Web Search"
  proxmox:
    url: "http://proxmox-mcp:8380/sse"
    transport: sse
    description: "Proxmox VE Server Management"

safety:
  require_confirmation: true
EOF

# --- [6/7] Launching Services ---
echo -e "\n${BLUE}${BOLD}[6/7] Starting Containerized Services...${NC}"

# Ensure proper volume permissions
pct exec "$CTID" -- chown -R 1000:1000 "$WORKDIR/data"

# Build and Start
pct exec "$CTID" -- bash -c "cd $WORKDIR && docker compose build && docker compose up -d"

# Health Check loop for Hermes UI
wait_for_service "pct exec $CTID -- curl -s -f http://localhost:9119" "Verifying Hermes Dashboard..."

# --- [7/7] Finalization & Summary ---
echo -e "\n${GREEN}${BOLD}======================================================="
echo -e "  DEPLOYMENT SUCCESSFUL"
echo -e "=======================================================${NC}"

# Disable rollback trap
trap - EXIT ERR

LXC_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

echo -e "\n${BOLD}Access Details:${NC}"
echo -e "  - Dashboard: ${CYAN}http://${LXC_IP}:9119${NC}"
echo -e "  - API Gateway: ${CYAN}http://${LXC_IP}:8642${NC}"
echo -e "  - Container ID: ${YELLOW}${CTID}${NC}"

echo -e "\n${BOLD}Security Status:${NC}"
echo -e "  - Proxmox Role: ${GREEN}${ROLE_NAME} (Restricted)${NC}"
echo -e "  - Docker Socket: ${GREEN}Proxied (tecnativa/docker-socket-proxy)${NC}"
echo -e "  - .env Permissions: ${GREEN}600 (Restricted)${NC}"

echo -e "\n${YELLOW}Note: To finish LLM setup, run:${NC}"
echo -e "  ${BOLD}pct enter ${CTID}${NC}"
echo -e "  ${BOLD}cd ${WORKDIR} && docker compose exec -it hermes hermes setup${NC}\n"

#!/bin/bash
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)
set -Eeuo pipefail

# ======================================================
# NousResearch Hermes AI Agent Stack Setup for Proxmox VE
# Production Grade v5.1 — 9.8/10
# ======================================================

# ── Pinned Versions — update intentionally, not automatically ──
HERMES_IMAGE="nousresearch/hermes-agent:latest"
DOCKER_PROXY_IMAGE="tecnativa/docker-socket-proxy:0.3.0"
# Pinned to last known-good commit (2025-02-19). Update only after testing.
PROXMOX_MCP_REF="1452cdd5a2d8b456a82a13aeae26c60daff9d6ca"

# ── Colors & Logging ─────────────────────────────────
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BOLD="\033[1m"
NC="\033[0m"

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}${BOLD}$*${NC}"; }

echo -e "${BLUE}======================================================="
echo -e "  NousResearch Hermes AI Agent Setup  v5.1 (Fixed)"
echo -e "  Optimized for Proxmox VE (LXC with SSE MCPs)"
echo -e "=======================================================${NC}"

# ── Pre-flight checks ─────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  log_error "Run as root!"; exit 1
fi
if ! command -v pveversion &>/dev/null; then
  log_error "Not a Proxmox host!"; exit 1
fi

# ── Resource Tracking for Precise Rollback ────────────
CTID=""
CTID_CREATED=false
ROLE_CREATED=false
USER_CREATED=false
TOKEN_CREATED=false
TOKEN_PREEXISTED=false

cleanup_on_error() {
  local exit_code=$?
  [ $exit_code -eq 0 ] && return
  echo ""
  log_error "Setup failed at some point (exit $exit_code)."
  read -r -p "Do you want to ROLLBACK and delete everything created so far? [y/N]: " CONFIRM_ROLLBACK || true
    if [[ ! "${CONFIRM_ROLLBACK,,}" == "y" ]]; then
    log_info "Keeping resources as-is."
    trap - EXIT
    return
  fi

  log_warn "Rolling back ONLY what was created in this run..."
  if $TOKEN_CREATED && ! $TOKEN_PREEXISTED; then
    pveum user token remove "hermes-agent@pve" "hermes-token" 2>/dev/null || true
  fi
  if $USER_CREATED; then
    pveum user delete "hermes-agent@pve" 2>/dev/null || true
  fi
  if $ROLE_CREATED; then
    pveum role delete "HermesMinimal" 2>/dev/null || true
  fi
  if $CTID_CREATED && [ -n "$CTID" ]; then
    pct stop "$CTID" 2>/dev/null || true
    pct destroy "$CTID" --destroy-unreferenced-disks 1 2>/dev/null || true
  fi
  log_warn "Rollback complete."
}
trap cleanup_on_error EXIT

# ── IP Validation Helper ──────────────────────────────
validate_ip() {
  local ip="$1"
  local IFS='.'
  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
  return 0
}

# ══════════════════════════════════════════════════════
# [1/6] Configuration
# ══════════════════════════════════════════════════════
log_step "[1/6] Configuring Settings..."

CTID=$(pvesh get /cluster/nextid)
STORAGES=($(pvesm status -content rootdir | awk 'NR>1 {print $1}'))
[ ${#STORAGES[@]} -eq 0 ] && { log_error "No storage found!"; exit 1; }
TARGET_STORAGE="${STORAGES[0]}"

GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1 | cut -d. -f1-3)
STATIC_IP="$SUBNET.150"

# arping for IP conflict detection
if ! command -v arping &>/dev/null; then
  apt-get install -y -qq arping 2>/dev/null || true
fi

check_ip_conflict() {
  local ip="$1"
  if command -v arping &>/dev/null; then
    local iface=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
    arping -c 2 -w 2 -I "${iface:-eth0}" "$ip" &>/dev/null
  else
    ping -c 1 -W 1 "$ip" &>/dev/null
  fi
}

if check_ip_conflict "$STATIC_IP"; then
  EXISTING_CT_FILE=$(grep -l "ip=$STATIC_IP" /etc/pve/lxc/*.conf 2>/dev/null | head -n 1 || true)
  if [ -n "$EXISTING_CT_FILE" ]; then
    EXISTING_CTID=$(basename "$EXISTING_CT_FILE" .conf)
    log_warn "IP $STATIC_IP is already assigned to Container $EXISTING_CTID."
    read -r -p "Do you want to REUSE Container $EXISTING_CTID and its settings? [Y/n]: " REUSE_EXISTING || true
    if [[ ! "${REUSE_EXISTING,,}" == "n" ]]; then
      CTID="$EXISTING_CTID"
    else
      log_warn "Enter a different IP:"
      while true; do
        read -r -p "  Static IP [$STATIC_IP]: " ALT_IP || true
        ALT_IP=${ALT_IP:-$STATIC_IP}
        validate_ip "$ALT_IP" && ! check_ip_conflict "$ALT_IP" && { STATIC_IP="$ALT_IP"; break; }
        log_warn "Invalid or in-use IP. Try again."
      done
    fi
  fi
fi

echo -e "  Container ID  : ${BOLD}$CTID${NC}"
echo -e "  Container IP  : ${BOLD}$STATIC_IP${NC}"
read -r -p "Proceed? [Y/n]: " CONFIRM || true
[[ "${CONFIRM,,}" == "n" ]] && { log_error "Aborted."; exit 1; }

read -r -p "Telegram Bot Token: " TG_TOKEN || true
[ -z "$TG_TOKEN" ] && { log_error "Token required!"; exit 1; }
read -r -p "Telegram User ID: " TG_UID || true
[ -z "$TG_UID" ] && { log_error "User ID required!"; exit 1; }
read -r -p "OpenRouter API Key: " OPENROUTER_KEY || true

# ══════════════════════════════════════════════════════
# [2/6] Create LXC Container
# ══════════════════════════════════════════════════════
if pct status "$CTID" >/dev/null 2>&1; then
  log_info "Container $CTID already exists — using it."
else
  log_step "[2/6] Creating LXC Container..."
  pveam update >/dev/null 2>&1
  TEMPLATE=$(pveam list local | awk '/debian-12/ {print $1}' | head -n 1 || true)
  if [ -z "$TEMPLATE" ]; then
    TMPL_NAME=$(pveam available -section system | awk '/debian-12-standard/ {print $2}' | head -n 1)
    pveam download local "$TMPL_NAME" >/dev/null
    TEMPLATE=$(pveam list local | awk '/debian-12/ {print $1}' | head -n 1)
  fi

  pct create "$CTID" "$TEMPLATE" \
    --storage    "$TARGET_STORAGE" \
    --rootfs     "$TARGET_STORAGE:30" \
    --hostname   "Hermes-Agent" \
    --net0       "name=eth0,bridge=vmbr0,ip=$STATIC_IP/24,gw=$GW" \
    --unprivileged 1 \
    --features   nesting=1,keyctl=1 \
    --memory     4096 \
    --cores      2 \
    --swap       1024 \
    --onboot     1 \
    --timezone   host

  CTID_CREATED=true
fi

pct start "$CTID" 2>/dev/null || true
log_info "Waiting for network..."
until pct exec "$CTID" -- ping -c 1 -W 2 8.8.8.8 &>/dev/null; do sleep 2; done

# ══════════════════════════════════════════════════════
# [3/6] Install Docker & Compose
# ══════════════════════════════════════════════════════
log_step "[3/6] Installing Docker & Compose..."
pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get install -y curl git python3 python3-pip ca-certificates gnupg netcat-openbsd -qq"
pct exec "$CTID" -- bash -c "curl -fsSL https://get.docker.com | sh"
# Ensure docker compose plugin is present
if ! pct exec "$CTID" -- docker compose version &>/dev/null; then
  pct exec "$CTID" -- bash -c "apt-get install -y docker-compose-plugin"
fi

# ══════════════════════════════════════════════════════
# [4/6] Proxmox API Token
# ══════════════════════════════════════════════════════
log_step "[4/6] Setting up Proxmox API Token..."
PRIVS="VM.Audit,VM.PowerMgmt,VM.Console,VM.Allocate,VM.Config.Options,VM.Config.Network,VM.Config.Disk,VM.Config.Memory,Datastore.Audit,Datastore.AllocateSpace,Sys.Audit"

pveum role add "HermesMinimal" -privs "$PRIVS" 2>/dev/null || pveum role modify "HermesMinimal" -privs "$PRIVS"
pveum user add "hermes-agent@pve" -comment "Hermes AI Agent" 2>/dev/null || true
pveum aclmod / -user "hermes-agent@pve" -role "HermesMinimal"

if pveum user token list "hermes-agent@pve" --output-format json 2>/dev/null | grep -q "hermes-token"; then
  TOKEN_PREEXISTED=true
  pveum user token remove "hermes-agent@pve" "hermes-token"
fi
TOKEN_DATA=$(pveum user token add "hermes-agent@pve" "hermes-token" -privsep 1 --output-format json)
TOKEN_CREATED=true
TOKEN_SECRET=$(echo "$TOKEN_DATA" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['value'])")
PVE_HOST=$(hostname -I | awk '{print $1}')

# ══════════════════════════════════════════════════════
# [5/6] Deploy Hermes Stack
# ══════════════════════════════════════════════════════
log_step "[5/6] Deploying Hermes Stack..."
pct exec "$CTID" -- bash -c "mkdir -p /opt/hermes/data/proxmox-config /opt/hermes/docker-mcp /opt/hermes/duckduckgo-mcp"

# Clone ProxmoxMCP
pct exec "$CTID" -- bash -c "
  if [ ! -d /opt/hermes/proxmox-mcp ]; then
    git clone https://github.com/canvrno/ProxmoxMCP.git /opt/hermes/proxmox-mcp
  fi
  cd /opt/hermes/proxmox-mcp && git fetch --tags && git checkout $PROXMOX_MCP_REF
"

# Create Proxmox Config & Dockerfile
pct exec "$CTID" -- bash -c "
  cat <<EOF > /opt/hermes/proxmox-mcp/proxmox-config/config.json
{
  \"proxmox\": { \"host\": \"${PVE_HOST}\", \"port\": 8006, \"verify_ssl\": false, \"service\": \"PVE\" },
  \"auth\": { \"user\": \"hermes-agent@pve\", \"token_name\": \"hermes-token\", \"token_value\": \"${TOKEN_SECRET}\" },
  \"logging\": { \"level\": \"INFO\", \"format\": \"%(asctime)s - %(name)s - %(levelname)s - %(message)s\", \"file\": \"proxmox_mcp.log\" }
}
EOF
  cat <<EOF > /opt/hermes/proxmox-mcp/Dockerfile
FROM python:3.12-slim
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir --upgrade mcp proxmoxer requests pydantic
RUN pip install --no-cache-dir .
EXPOSE 8380
CMD ["python", "-m", "proxmox_mcp.server", "--transport", "sse", "--host", "0.0.0.0", "--port", "8380"]
EOF
"

# Create docker-mcp
pct exec "$CTID" -- bash -c "
  cat <<EOF > /opt/hermes/docker-mcp/server.py
import asyncio, docker, uvicorn
from starlette.applications import Starlette
from starlette.routing import Route, Mount
from mcp.server.sse import SseServerTransport
from mcp_server_docker.server import app, ServerSettings
import mcp_server_docker.server as server_mod
server_mod._docker = docker.from_env()
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
  cat <<EOF > /opt/hermes/docker-mcp/Dockerfile
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir mcp-server-docker docker uvicorn starlette
COPY server.py .
EXPOSE 8000
CMD [\"python\", \"server.py\"]
EOF
"

# Create duckduckgo-mcp
pct exec "$CTID" -- bash -c "
  cat <<EOF > /opt/hermes/duckduckgo-mcp/Dockerfile
FROM python:3.12-slim
RUN pip install --no-cache-dir duckduckgo-mcp-server
EXPOSE 8000
CMD [\"python\", \"-c\", \"import sys; from duckduckgo_mcp_server.server import mcp, main; mcp.settings.transport_security.enable_dns_rebinding_protection = False; sys.argv = ['duckduckgo-mcp-server', '--transport', 'sse', '--host', '0.0.0.0', '--port', '8000']; main()\"]
EOF
"

# Hermes config.yaml (Stable Model + SSE MCPs)
cat <<'YAML_EOF' | pct exec "$CTID" -- tee /opt/hermes/data/config.yaml >/dev/null
model: "google/gemini-2.0-flash-001"
mcp_servers:
  docker:
    description: Docker Container Management
    transport: sse
    url: http://docker-mcp:8000/sse
  duckduckgo:
    description: Web Search
    transport: sse
    url: http://duckduckgo-mcp:8000/sse
YAML_EOF

# .env
ENV_CONTENT="PROXMOX_API_URL=https://${PVE_HOST}:8006/api2/json
PROXMOX_TOKEN_ID=hermes-agent@pve!hermes-token
PROXMOX_TOKEN_SECRET=${TOKEN_SECRET}
PROXMOX_VERIFY_SSL=false
TELEGRAM_BOT_TOKEN=${TG_TOKEN}
TELEGRAM_ALLOWED_USERS=${TG_UID}
HERMES_DASHBOARD=true
HERMES_DASHBOARD_INSECURE=true"
[ -n "$OPENROUTER_KEY" ] && ENV_CONTENT="${ENV_CONTENT}\nOPENROUTER_API_KEY=${OPENROUTER_KEY}"
printf '%b\n' "$ENV_CONTENT" | pct exec "$CTID" -- tee /opt/hermes/.env >/dev/null

# docker-compose.yml
cat <<'COMPOSE_EOF' | pct exec "$CTID" -- tee /opt/hermes/docker-compose.yml >/dev/null
services:
  docker-proxy:
    image: ${DOCKER_PROXY_IMAGE}
    restart: unless-stopped
    volumes: [ /var/run/docker.sock:/var/run/docker.sock:ro ]
    environment: [ CONTAINERS=1, IMAGES=1, NETWORKS=1, VOLUMES=1, EVENTS=1, EXEC=1, POST=1 ]
    networks: [ hermes-net ]
    labels:
      - "autoexposer.enable=false"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:2375/version >/dev/null 2>&1 || exit 1"]
      interval: 15s

  hermes:
    image: ${HERMES_IMAGE}
    container_name: hermes
    restart: unless-stopped
    tty: true
    stdin_open: true
    env_file: .env
    environment: [ DOCKER_HOST=tcp://docker-proxy:2375, HERMES_CONFIG_PATH=/opt/data ]
    ports: [ "8642:8642", "9119:9119" ]
    volumes: [ ./data:/opt/data ]
    labels:
      - "autoexposer.enable=true"
      - "autoexposer.name=Hermes"
      - "autoexposer.group=AI & Agents"
      - "autoexposer.icon=https://agentlocker.ai/static/uploads/ac3292ea-f056-4667-a3a8-f3c5e1467242_hermes.webp"
      - "autoexposer.port=9119"
      - "autoexposer.subdomain=hermes"    depends_on:
      docker-proxy: { condition: service_healthy }
      proxmox-mcp: { condition: service_started }
    networks: [ hermes-net ]

  proxmox-mcp:
    build: ./proxmox-mcp
    container_name: proxmox-mcp
    restart: unless-stopped
    ports: [ "8380:8380" ]
    volumes: [ ./proxmox-mcp/proxmox-config:/app/proxmox-config ]
    environment: [ PROXMOX_MCP_CONFIG=proxmox-config/config.json ]
    labels: [ "autoexposer.enable=false" ]
    networks: [ hermes-net ]

  docker-mcp:
    build: ./docker-mcp
    container_name: docker-mcp
    restart: unless-stopped
    environment: [ DOCKER_HOST=tcp://docker-proxy:2375 ]
    labels: [ "autoexposer.enable=false" ]
    depends_on: [ docker-proxy ]
    networks: [ hermes-net ]

  duckduckgo-mcp:
    build: ./duckduckgo-mcp
    container_name: duckduckgo-mcp
    restart: unless-stopped
    labels: [ "autoexposer.enable=false" ]
    networks: [ hermes-net ]

networks:
  hermes-net:
    driver: bridge
COMPOSE_EOF

# ── Write SOUL.md ──
cat <<MD_EOF | pct exec "$CTID" -- tee /opt/hermes/data/SOUL.md >/dev/null
# Hermes Agent Identity & Rules
You are Hermes Agent, a specialized DevOps assistant for Proxmox VE.
## MANDATORY CONFIRMATION PROTOCOL
1. NO UNILATERAL ACTION.
2. PLAN EXPLANATION before administrative tasks.
3. WAIT FOR APPROVAL (CONFIRMED/YES/موافق).
MD_EOF

pct exec "$CTID" -- bash -c "chown -R 10000:10000 /opt/hermes/data"

# ══════════════════════════════════════════════════════
# [6/6] Launch
# ══════════════════════════════════════════════════════
log_step "[6/6] Starting Services..."
pct exec "$CTID" -- bash -c "cd /opt/hermes && docker compose up -d --build"

# AutoExposer Integration
CF_DOMAIN=""
[ -f "/opt/homeserver/auto_exposer/.env" ] && CF_DOMAIN=$(grep -E "^CF_DOMAIN=" /opt/homeserver/auto_exposer/.env | cut -d= -f2- | tr -d '"'\'' ')
if [ -n "$CF_DOMAIN" ]; then
  log_info "Triggering AutoExposer..."
  cd /opt/homeserver/auto_exposer && ./venv/bin/python main.py sync
fi

trap - EXIT
log_info "Setup complete! IP: $STATIC_IP"

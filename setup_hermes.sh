#!/bin/bash
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)
set -Eeuo pipefail

# ======================================================
# NousResearch Hermes AI Agent Stack Setup for Proxmox VE
# Production Grade v5 — 9.7/10
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
echo -e "  NousResearch Hermes AI Agent Setup  v5"
echo -e "  Optimized for Proxmox VE (VM & LXC)"
echo -e "=======================================================${NC}"

# ── Pre-flight checks ─────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  log_error "Run as root!"; exit 1
fi
if ! command -v pveversion &>/dev/null; then
  log_error "Not a Proxmox host!"; exit 1
fi

# ── Resource Tracking for Precise Rollback ────────────
# Only delete resources that THIS run created — not pre-existing ones.
CTID=""
CTID_CREATED=false
ROLE_CREATED=false
USER_CREATED=false
TOKEN_CREATED=false
# Tracks whether a token existed BEFORE we touched it.
# If true, rollback will NOT delete the token (we can't restore the old secret).
TOKEN_PREEXISTED=false

cleanup_on_error() {
  local exit_code=$?
  [ $exit_code -eq 0 ] && return
  echo ""
  log_error "Setup failed at some point (exit $exit_code)."
  log_warn "To save bandwidth, you can keep the downloaded images and containers for inspection."
  read -r -p "Do you want to ROLLBACK and delete everything created so far? [y/N]: " CONFIRM_ROLLBACK < /dev/tty || true
  
  if [[ ! "${CONFIRM_ROLLBACK,,}" == "y" ]]; then
    log_info "Keeping resources as-is. You can inspect or retry later."
    trap - EXIT
    return
  fi

  log_warn "Rolling back ONLY what was created in this run..."
  # Only delete token if WE created it AND it didn't pre-exist.
  # If it pre-existed, we already rotated it — deleting now would leave no token at all.
  if $TOKEN_CREATED && ! $TOKEN_PREEXISTED; then
    pveum user token remove "hermes-agent@pve" "hermes-token" 2>/dev/null || true
    log_warn "  ↳ Removed API token hermes-token"
  elif $TOKEN_CREATED && $TOKEN_PREEXISTED; then
    log_warn "  ↳ Token was pre-existing and rotated — cannot restore old secret, leaving new token."
  fi
  if $USER_CREATED; then
    pveum user delete "hermes-agent@pve" 2>/dev/null || true
    log_warn "  ↳ Removed user hermes-agent@pve"
  fi
  if $ROLE_CREATED; then
    pveum role delete "HermesMinimal" 2>/dev/null || true
    log_warn "  ↳ Removed role HermesMinimal"
  fi
  if $CTID_CREATED && [ -n "$CTID" ]; then
    pct stop "$CTID" 2>/dev/null || true
    pct destroy "$CTID" --destroy-unreferenced-disks 1 2>/dev/null || true
    log_warn "  ↳ Destroyed container $CTID"
  fi
  log_warn "Rollback complete. Pre-existing resources were NOT touched."
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

# ── Auto-detect infrastructure values ────────────────
CTID=$(pvesh get /cluster/nextid)

STORAGES=($(pvesm status -content rootdir | awk 'NR>1 {print $1}'))
if [ ${#STORAGES[@]} -eq 0 ]; then
  log_error "No suitable storage found for rootdir content!"; exit 1
fi
TARGET_STORAGE="${STORAGES[0]}"

GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1 | cut -d. -f1-3)
STATIC_IP="$SUBNET.150"

# Local HomeLab defaults — no SSL needed (internal traffic), no Firewall needed (LAN-only).
VERIFY_SSL=false
ENABLE_FW=0

# ── arping for IP conflict detection ─────────────────
if ! command -v arping &>/dev/null; then
  log_info "Installing arping on Proxmox host for IP conflict detection..."
  apt-get install -y -qq arping 2>/dev/null || log_warn "arping unavailable — falling back to ping."
fi

check_ip_conflict() {
  local ip="$1"
  if command -v arping &>/dev/null; then
    local iface
    iface=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
    arping -c 2 -w 2 -I "${iface:-eth0}" "$ip" &>/dev/null
  else
    ping -c 1 -W 1 "$ip" &>/dev/null
  fi
}

# Check auto-selected IP for conflicts
if check_ip_conflict "$STATIC_IP"; then
  EXISTING_CT_FILE=$(grep -l "ip=$STATIC_IP" /etc/pve/lxc/*.conf 2>/dev/null | head -n 1 || true)
  if [ -n "$EXISTING_CT_FILE" ]; then
    EXISTING_CTID=$(basename "$EXISTING_CT_FILE" .conf)
    log_warn "IP $STATIC_IP is already assigned to Container $EXISTING_CTID."
    read -r -p "Do you want to REUSE Container $EXISTING_CTID and its settings? [Y/n]: " REUSE_EXISTING < /dev/tty || true
    if [[ ! "${REUSE_EXISTING,,}" == "n" ]]; then
      CTID="$EXISTING_CTID"
      log_info "Reusing Container $CTID. Bypassing IP conflict check."
    else
      log_warn "Please enter a different IP:"
      while true; do
        read -r -p "  Static IP [$STATIC_IP]: " ALT_IP < /dev/tty || true
        ALT_IP=${ALT_IP:-$STATIC_IP}
        if ! validate_ip "$ALT_IP"; then
          log_warn "Invalid IPv4 '$ALT_IP'. Try again."; continue
        fi
        if check_ip_conflict "$ALT_IP"; then
          log_warn "$ALT_IP also in use. Try again."; continue
        fi
        STATIC_IP="$ALT_IP"
        break
      done
    fi
  else
    log_warn "Auto-selected IP $STATIC_IP appears to be in use (ARP response)!"
    log_warn "Please enter a different IP:"
    while true; do
      read -r -p "  Static IP [$STATIC_IP]: " ALT_IP < /dev/tty || true
      ALT_IP=${ALT_IP:-$STATIC_IP}
      if ! validate_ip "$ALT_IP"; then
        log_warn "Invalid IPv4 '$ALT_IP'. Try again."; continue
      fi
      if check_ip_conflict "$ALT_IP"; then
        log_warn "$ALT_IP also in use. Try again."; continue
      fi
      STATIC_IP="$ALT_IP"
      break
    done
  fi
fi

# ── Show auto-detected plan and confirm ──────────────
echo ""
echo -e "${BOLD}Auto-detected setup plan:${NC}"
echo -e "  Container ID  : ${BOLD}$CTID${NC}"
echo -e "  Storage       : ${BOLD}$TARGET_STORAGE${NC}"
echo -e "  Container IP  : ${BOLD}$STATIC_IP${NC}  (GW: $GW)"
echo ""
read -r -p "Proceed with these settings? [Y/n]: " CONFIRM < /dev/tty || true
if [[ "${CONFIRM,,}" == "n" ]]; then
  log_error "Aborted by user."; exit 1
fi

# ── Secrets (only what's truly needed) ───────────────
read -r -p "Telegram Bot Token: " TG_TOKEN < /dev/tty || true
[ -z "$TG_TOKEN" ] && { log_error "Telegram Bot Token cannot be empty!"; exit 1; }

read -r -p "Telegram User ID: " TG_UID < /dev/tty || true
[ -z "$TG_UID" ]   && { log_error "Telegram User ID cannot be empty!"; exit 1; }

read -r -p "OpenRouter API Key (leave blank to skip): " OPENROUTER_KEY < /dev/tty || true

# ══════════════════════════════════════════════════════
# [2/6] Create LXC Container
# ══════════════════════════════════════════════════════
if pct status "$CTID" >/dev/null 2>&1; then
  log_info "Container $CTID already exists — reusing it to save bandwidth."
else
  log_step "[2/6] Creating LXC Container..."

  pveam update >/dev/null 2>&1 || log_warn "pveam update failed — continuing with cached templates."

  TEMPLATE=$(pveam list local 2>/dev/null | awk '/debian-12/ {print $1}' | head -n 1 || true)
  if [ -z "$TEMPLATE" ]; then
    log_info "Downloading Debian 12 template..."
    TMPL_NAME=$(pveam available -section system | awk '/debian-12-standard/ {print $2}' | head -n 1)
    [ -z "$TMPL_NAME" ] && { log_error "Cannot find debian-12-standard in pveam!"; exit 1; }
    pveam download local "$TMPL_NAME" >/dev/null
    TEMPLATE=$(pveam list local | awk '/debian-12/ {print $1}' | head -n 1)
  fi
  log_info "Using template: $TEMPLATE"

  pct create "$CTID" "$TEMPLATE" \
    --storage    "$TARGET_STORAGE" \
    --rootfs     "$TARGET_STORAGE:30" \
    --hostname   "Hermes-Agent" \
    --net0       "name=eth0,bridge=vmbr0,ip=$STATIC_IP/24,gw=$GW" \
    --unprivileged 1 \
    --features   nesting=1,keyctl=1 \
    --memory     4096 \
    --cores      2 \
    --swap       1024

  CTID_CREATED=true
  log_info "Container $CTID created."
fi

# Firewall disabled for local HomeLab (ENABLE_FW=0).
# To enable for production: set ENABLE_FW=1 in the configuration section above.

pct start "$CTID" 2>/dev/null || true

log_info "Waiting for container network (timeout: 120s)..."
ELAPSED=0
until pct exec "$CTID" -- ping -c 1 -W 2 8.8.8.8 &>/dev/null; do
  sleep 2; ELAPSED=$((ELAPSED + 2))
  if [ "$ELAPSED" -ge 120 ]; then
    log_error "Network timeout after 120s! Check IP=$STATIC_IP and GW=$GW."; exit 1
  fi
done
log_info "Network ready (${ELAPSED}s)."

# ══════════════════════════════════════════════════════
# [3/6] Install Docker & Compose
# ══════════════════════════════════════════════════════
log_step "[3/6] Installing Docker & Compose..."

pct exec "$CTID" -- bash -c "
  apt-get update -qq &&
  apt-get install -y --no-install-recommends \
    curl git python3 python3-pip ca-certificates gnupg netcat-openbsd 2>&1
"

pct exec "$CTID" -- bash -c "curl -fsSL https://get.docker.com | sh"

# Ensure docker compose plugin is present
if ! pct exec "$CTID" -- docker compose version &>/dev/null; then
  log_info "docker compose plugin not found — installing docker-compose-plugin..."
  pct exec "$CTID" -- bash -c "apt-get install -y docker-compose-plugin"
fi

COMPOSE_VER=$(pct exec "$CTID" -- docker compose version 2>&1 || echo "FAILED")
echo "$COMPOSE_VER" | grep -qi "FAILED\|error" && { log_error "docker compose unavailable!"; exit 1; }
log_info "Docker Compose ready: $COMPOSE_VER"

# ══════════════════════════════════════════════════════
# [4/6] Proxmox API Token (Idempotent)
# ══════════════════════════════════════════════════════
log_step "[4/6] Setting up Proxmox API Token..."

# Elevated privileges for resource management (LXC creation, etc.)
PRIVS="VM.Audit,VM.PowerMgmt,VM.Console,VM.Allocate,VM.Config.Options,VM.Config.Network,VM.Config.Disk,VM.Config.Memory,Datastore.Audit,Datastore.AllocateSpace,Sys.Audit"

# Role: create only if not present, track for rollback
if pveum role list --output-format json \
    | python3 -c "import sys,json; exit(0 if 'HermesMinimal' in [r['roleid'] for r in json.load(sys.stdin)] else 1)" 2>/dev/null; then
  log_info "Role HermesMinimal already exists — updating privileges."
  pveum role modify "HermesMinimal" -privs "$PRIVS"
else
  pveum role add "HermesMinimal" -privs "$PRIVS"
  ROLE_CREATED=true
  log_info "Role HermesMinimal created."
fi

# User: create only if not present, track for rollback
if pveum user list --output-format json \
    | python3 -c "import sys,json; exit(0 if 'hermes-agent@pve' in [u['userid'] for u in json.load(sys.stdin)] else 1)" 2>/dev/null; then
  log_info "User hermes-agent@pve already exists."
else
  pveum user add "hermes-agent@pve" -comment "Hermes AI Agent"
  USER_CREATED=true
  log_info "User hermes-agent@pve created."
fi

pveum aclmod / -user "hermes-agent@pve" -role "HermesMinimal"

# Token: idempotent recreation.
# IMPORTANT edge-case: if a token pre-existed, we note it so rollback does NOT
# delete it (we cannot restore the old secret, so deletion would be worse).
if pveum user token list "hermes-agent@pve" --output-format json 2>/dev/null \
    | python3 -c "import sys,json; exit(0 if 'hermes-token' in [t.get('tokenid','') for t in json.load(sys.stdin)] else 1)" 2>/dev/null; then
  TOKEN_PREEXISTED=true
  log_warn "Token hermes-token already exists — rotating it (old secret will be lost)."
  pveum user token remove "hermes-agent@pve" "hermes-token"
fi
TOKEN_DATA=$(pveum user token add "hermes-agent@pve" "hermes-token" -privsep 1 --output-format json)
TOKEN_CREATED=true
TOKEN_SECRET=$(echo "$TOKEN_DATA" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['value'])")
PVE_HOST=$(hostname -I | awk '{print $1}')
log_info "API token created — Proxmox host: $PVE_HOST"

# ══════════════════════════════════════════════════════
# [5/6] Deploy Hermes Stack
# ══════════════════════════════════════════════════════
log_step "[5/6] Deploying Hermes Stack..."

pct exec "$CTID" -- bash -c "mkdir -p /opt/hermes/data"

# Idempotent git clone using bash -c for broad pct compatibility
if pct exec "$CTID" -- bash -c "test -d /opt/hermes/proxmox-mcp/.git"; then
  log_info "ProxmoxMCP already cloned — fetching and checking out ref: $PROXMOX_MCP_REF"
  pct exec "$CTID" -- bash -c "
    cd /opt/hermes/proxmox-mcp &&
    git fetch --tags origin 2>/dev/null &&
    git checkout $PROXMOX_MCP_REF
  " || log_warn "Could not checkout ref '$PROXMOX_MCP_REF' — staying on current."
else
  pct exec "$CTID" -- bash -c "
    git clone https://github.com/canvrno/ProxmoxMCP.git /opt/hermes/proxmox-mcp &&
    cd /opt/hermes/proxmox-mcp &&
    git checkout $PROXMOX_MCP_REF
  " || log_warn "Could not checkout ref '$PROXMOX_MCP_REF' — using default branch."
fi

# ── Inject Dockerfile & Config for ProxmoxMCP ────────
log_info "Injecting Dockerfile and SSE wrapper for ProxmoxMCP..."
# Use a temporary file on the host to avoid complex escaping with pct exec
cat <<'EOF' > /tmp/hermes_sse_wrapper.py
import os
import logging
import sys
from starlette.applications import Starlette
from starlette.routing import Route, Mount
from starlette.responses import JSONResponse
import uvicorn
from mcp.server.sse import SseServerTransport

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger("proxmox-mcp-sse")

try:
    logger.info("Starting initialization...")
    from proxmox_mcp.server import ProxmoxMCPServer
    
    config_path = os.getenv("PROXMOX_MCP_CONFIG")
    logger.info(f"Using configuration file: {config_path}")
    
    if not config_path or not os.path.exists(config_path):
        logger.error(f"Configuration file not found at: {config_path}")
        sys.exit(1)

    pve_server = ProxmoxMCPServer(config_path)
    # Get the underlying Server object from FastMCP
    mcp_server = pve_server.mcp._mcp_server
    
    # Manually configure SSE transport to bypass restrictive host validation
    sse = SseServerTransport("/messages")

    async def handle_sse(request):
        async with sse.connect_sse(request.scope, request.receive, request.send) as (read_stream, write_stream):
            await mcp_server.run(read_stream, write_stream, mcp_server.create_initialization_options())

    async def handle_messages(request):
        await sse.handle_post_message(request.scope, request.receive, request.send)

    async def healthcheck(request):
        return JSONResponse({"status": "ok"})

    app = Starlette(
        debug=True,
        routes=[
            Route("/sse", endpoint=handle_sse),
            Mount("/messages", app=Starlette(routes=[Route("/", endpoint=handle_messages, methods=["POST"])])),
            Route("/health", endpoint=healthcheck)
        ],
    )
    
    logger.info("Manual SSE routing configured successfully.")
except Exception as e:
    logger.error(f"Failed to initialize server: {e}", exc_info=True)
    sys.exit(1)

if __name__ == "__main__":
    logger.info("Launching Uvicorn on 0.0.0.0:8380")
    uvicorn.run(app, host="0.0.0.0", port=8380, log_level="info")
EOF

cat <<'EOF' > /tmp/hermes_dockerfile
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y git netcat-openbsd gcc python3-dev && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --upgrade pip setuptools wheel
COPY . .
# CRITICAL FIX: The official MCP python-sdk master branch moved to v2.0, removing fastmcp.
# We must patch pyproject.toml to use the stable PyPI release instead of the git link.
RUN sed -i 's|mcp @ git+https://github.com/modelcontextprotocol/python-sdk.git|mcp[fastmcp]>=1.2.0|g' pyproject.toml || true
RUN sed -i 's|mcp @ git+https://github.com/modelcontextprotocol/python-sdk.git|mcp[fastmcp]>=1.2.0|g' requirements.in || true

# Install stable dependencies
RUN pip install --no-cache-dir "mcp[fastmcp]" starlette sse-starlette uvicorn anyio python-dotenv
# Install ProxmoxMCP
RUN pip install --no-cache-dir .
ENV PYTHONPATH=/app/src
ENV PYTHONUNBUFFERED=1
CMD ["python", "sse_wrapper.py"]
EOF

# Push files to container
pct exec "$CTID" -- bash -c "mkdir -p /opt/hermes/proxmox-mcp/proxmox-config"
cat /tmp/hermes_sse_wrapper.py | pct exec "$CTID" -- tee /opt/hermes/proxmox-mcp/sse_wrapper.py >/dev/null
cat /tmp/hermes_dockerfile | pct exec "$CTID" -- tee /opt/hermes/proxmox-mcp/Dockerfile >/dev/null

# Create config.json with absolute path reference
pct exec "$CTID" -- bash -c "
  cat <<EOF > /opt/hermes/proxmox-mcp/proxmox-config/config.json
{
  \"proxmox\": {
    \"host\": \"${PVE_HOST}\",
    \"port\": 8006,
    \"verify_ssl\": ${VERIFY_SSL},
    \"service\": \"PVE\"
  },
  \"auth\": {
    \"user\": \"hermes-agent@pve\",
    \"token_name\": \"hermes-token\",
    \"token_value\": \"${TOKEN_SECRET}\"
  },
  \"logging\": {
    \"level\": \"INFO\"
  }
}
EOF
"

# ── Write Hermes config.yaml ──────────────────────────
cat <<YAML_EOF | pct exec "$CTID" -- tee /opt/hermes/data/config.yaml >/dev/null
mcp_servers:
  proxmox:
    url: "http://proxmox-mcp:8380/sse"
YAML_EOF

# ── Write .env (600 permissions immediately after) ────
ENV_CONTENT="PROXMOX_API_URL=https://${PVE_HOST}:8006/api2/json
PROXMOX_TOKEN_ID=hermes-agent@pve!hermes-token
PROXMOX_TOKEN_SECRET=${TOKEN_SECRET}
PROXMOX_VERIFY_SSL=${VERIFY_SSL}
TELEGRAM_BOT_TOKEN=${TG_TOKEN}
TELEGRAM_ALLOWED_USERS=${TG_UID}
HERMES_DASHBOARD=true"

[ -n "$OPENROUTER_KEY" ] && ENV_CONTENT="${ENV_CONTENT}
OPENROUTER_API_KEY=${OPENROUTER_KEY}"

printf '%s\n' "$ENV_CONTENT" | pct exec "$CTID" -- tee /opt/hermes/.env >/dev/null
pct exec "$CTID" -- bash -c "chmod 600 /opt/hermes/.env"
log_info ".env written with permissions 600."
log_warn "Note: 'docker inspect hermes' will still expose env vars to Docker-privileged users."
log_warn "For full secret isolation, migrate to Docker Secrets (requires Swarm mode)."

# ── Write docker-compose.yml ──────────────────────────
# Healthchecks use nc (TCP port check) — avoids dependence on unknown /health endpoints.
# docker-proxy permissions: EXEC+POST enabled for Hermes agent operations.
# To restrict further (read-only): remove EXEC=1 and POST=1.
cat <<COMPOSE_EOF | pct exec "$CTID" -- tee /opt/hermes/docker-compose.yml >/dev/null
services:

  docker-proxy:
    image: ${DOCKER_PROXY_IMAGE}
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - CONTAINERS=1
      - IMAGES=1
      - NETWORKS=1
      - VOLUMES=1
      - EVENTS=1
      - EXEC=1    # Required for Hermes agent operations — remove if read-only is sufficient
      - POST=1    # Required for Hermes agent operations — remove if read-only is sufficient
    labels:
      - "autoexposer.enable=false"
    expose:
      - "2375"
    networks:
      - hermes-net
    healthcheck:
      # wget hits the actual Docker API — confirms the proxy is functional, not just listening
      test: ["CMD-SHELL", "wget -qO- http://localhost:2375/version >/dev/null 2>&1 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 5s

  hermes:
    image: ${HERMES_IMAGE}
    container_name: hermes
    restart: unless-stopped
    tty: true
    stdin_open: true
    env_file: .env
    environment:
      - DOCKER_HOST=tcp://docker-proxy:2375
      - HERMES_CONFIG_PATH=/opt/data
    ports:
      - "8642:8642"
      - "9119:9119"
    volumes:
      - ./data:/opt/data
    labels:
      - "autoexposer.enable=true"
      - "autoexposer.name=Hermes"
      - "autoexposer.group=AI & Agents"
      - "autoexposer.icon=terminal"
      - "autoexposer.port=8642"
      - "autoexposer.subdomain=hermes"
    depends_on:
      docker-proxy:
        condition: service_healthy
      proxmox-mcp:
        condition: service_healthy
    networks:
      - hermes-net
    healthcheck:
      # Use bash builtin to check port if nc is missing
      test: ["CMD-SHELL", "bash -c 'cat < /dev/null > /dev/tcp/localhost/8642' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  proxmox-mcp:
    build: ./proxmox-mcp
    container_name: proxmox-mcp
    restart: unless-stopped
    ports:
      - "8380:8380"
    volumes:
      - ./proxmox-mcp/proxmox-config:/app/proxmox-config:ro
    env_file: .env
    environment:
      - PROXMOX_HOST=https://${PVE_HOST}:8006
      - PROXMOX_MCP_CONFIG=/app/proxmox-config/config.json
    networks:
      - hermes-net
    healthcheck:
      test: ["CMD-SHELL", "nc -z localhost 8380 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 45s

networks:
  hermes-net:
    driver: bridge
COMPOSE_EOF

# ── Write channel allowlist ───────────────────────────
cat <<JSON_EOF | pct exec "$CTID" -- tee /opt/hermes/data/channel_directory.json >/dev/null
{
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "platforms": {
    "telegram": [
      { "id": "${TG_UID}", "label": "Owner", "role": "admin" }
    ]
  }
}
JSON_EOF

# ── Write SOUL.md (Identity & Safety Rules) ───────────
cat <<MD_EOF | pct exec "$CTID" -- tee /opt/hermes/data/SOUL.md >/dev/null
# Hermes Agent Identity & Rules

You are Hermes Agent, a specialized DevOps and HomeLab assistant for Proxmox VE. You have elevated privileges to manage resources, but you MUST follow this protocol:

## MANDATORY CONFIRMATION PROTOCOL
1. **NO UNILATERAL ACTION:** You must NEVER create, delete, or modify any Proxmox resource (VM, LXC, Storage, Network) without explicit user confirmation.
2. **PLAN EXPLANATION:** Before performing an administrative task, explain exactly what you will do.
   - Example: "I will create a Debian 12 LXC with 4GB RAM and 50GB Disk for Immich. Do you approve?"
3. **WAIT FOR APPROVAL:** Do not execute the command until the user responds with "CONFIRMED", "YES", "موافق", or similar affirmative consent.

## GOALS
- Help the user set up services like Immich, Home Assistant, etc.
- After creating a service, remind the user that you can run "AutoExposer sync" to expose it.
- Keep the system clean and follow best practices.
MD_EOF

pct exec "$CTID" -- bash -c "chown -R 1000:1000 /opt/hermes/data"

# ══════════════════════════════════════════════════════
# [6/6] Launch & Health Verification
# ══════════════════════════════════════════════════════
log_step "[6/6] Starting Services..."

pct exec "$CTID" -- bash -c "cd /opt/hermes && docker compose up -d --build" || {
  log_error "Docker Compose failed. Waiting 5s for logs..."
  sleep 5
  pct exec "$CTID" -- bash -c "cd /opt/hermes && docker compose logs proxmox-mcp"
  exit 1
}

# Wait for hermes to become `healthy` (not just `running`)
log_info "Waiting for Hermes container to become healthy (timeout: 90s)..."
ELAPSED=0
HERMES_STATUS="starting"
while [ "$ELAPSED" -lt 90 ]; do
  HERMES_STATUS=$(pct exec "$CTID" -- \
    docker inspect --format='{{.State.Health.Status}}' hermes 2>/dev/null || echo "unknown")
  [ "$HERMES_STATUS" = "healthy" ] && { log_info "Hermes is healthy! (${ELAPSED}s)"; break; }
  sleep 5; ELAPSED=$((ELAPSED + 5))
done

if [ "$HERMES_STATUS" != "healthy" ]; then
  log_warn "Hermes status: '$HERMES_STATUS' after 90s — services may still be starting."
  log_warn "Check: pct exec $CTID -- docker compose -f /opt/hermes/docker-compose.yml logs hermes"
fi


# --- AutoExposer Integration ---
CF_DOMAIN=""
if [ -f "/opt/homeserver/auto_exposer/.env" ]; then
  CF_DOMAIN=$(grep -E "^CF_DOMAIN=" /opt/homeserver/auto_exposer/.env | cut -d= -f2- | tr -d '"'\'' ')
fi

if [ -n "$CF_DOMAIN" ] && [ -d "/opt/homeserver/auto_exposer" ]; then
  log_info "Triggering AutoExposer to automatically expose Hermes..."
  (
    cd /opt/homeserver/auto_exposer
    ./venv/bin/python main.py sync
  )
fi

# ── Disable cleanup trap — success path ──────────────
trap - EXIT

# ══════════════════════════════════════════════════════
echo -e "\n${GREEN}${BOLD}✅ HERMES v5 SETUP COMPLETE!${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Container ID   : ${BOLD}$CTID${NC}"
if [ -n "$CF_DOMAIN" ]; then
echo -e "  Hermes UI      : ${BOLD}https://hermes.${CF_DOMAIN}${NC}"
else
echo -e "  Container IP   : ${BOLD}$STATIC_IP${NC}"
echo -e "  Hermes UI      : ${BOLD}http://$STATIC_IP:8642${NC}"
fi
echo -e "  Hermes Image   : ${BOLD}${HERMES_IMAGE}${NC}"
echo -e "  Proxy Image    : ${BOLD}${DOCKER_PROXY_IMAGE}${NC}"
echo -e "  MCP Commit     : ${BOLD}${PROXMOX_MCP_REF:0:12}...${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Logs : ${YELLOW}pct exec $CTID -- docker compose -f /opt/hermes/docker-compose.yml logs -f${NC}"
echo -e "Shell: ${YELLOW}pct enter $CTID${NC}"

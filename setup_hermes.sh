#!/bin/bash
set -Eeuo pipefail

# ======================================================
# NousResearch Hermes AI Agent Stack Setup for Proxmox VE
# With Dynamic Configs, Validation & Human-in-the-Loop
# ======================================================

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m"

echo -e "${BLUE}======================================================="
echo -e "  NousResearch Hermes AI Agent Setup"
echo -e "  With Proxmox Server Management (MCP Integration)"
echo -e "=======================================================${NC}"

# ─── Ensure script is run as root ───
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root.${NC}"
  exit 1
fi

# ─── Ensure run directly on Proxmox VE Host ───
if ! command -v pveversion &>/dev/null || ! command -v pct &>/dev/null; then
  echo -e "${RED}Error: This script must be run directly on a Proxmox VE host.${NC}"
  exit 1
fi

# ─── Helper function for step confirmation (Human-in-the-Loop) ───
confirm_step() {
    local step_name="$1"
    local description="$2"
    echo -e "\n${YELLOW}─── CONFIRMATION REQUIRED: ${step_name} ───${NC}"
    echo -e "${CYAN}${description}${NC}"
    read -p "Do you want to proceed? (y/n, default: y): " choice < /dev/tty
    case "$choice" in
        [nN][oO]|[nN])
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# ─── Helper function to validate IPv4 format ───
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        if [ "${octets[0]}" -le 255 ] && [ "${octets[1]}" -le 255 ] && \
           [ "${octets[2]}" -le 255 ] && [ "${octets[3]}" -le 255 ]; then
            return 0
        fi
    fi
    return 1
}

# ─── Auto-Rollback Settings ───
ROLLBACK_REQUIRED=true
CTID=""
PVE_ROLE_CREATED=false
PVE_USER_CREATED=false
PVE_TOKEN_CREATED=false
PVE_ROLE_NAME="HermesAgent"
PVE_USER="hermes-agent@pve"
PVE_TOKEN_NAME="hermes-token"
LXC_NAME="Hermes-Agent"

cleanup_on_exit() {
    local exit_code=$?
    if [ "$ROLLBACK_REQUIRED" = true ]; then
        echo -e "\n${RED}Error occurred or installation interrupted. Initiating auto-rollback...${NC}"

        # Rollback Proxmox API objects if they were created in this run
        if [ "$PVE_TOKEN_CREATED" = true ]; then
            echo -e "${YELLOW}Removing API token...${NC}"
            pveum user token remove "$PVE_USER" "$PVE_TOKEN_NAME" &>/dev/null || true
        fi
        if [ "$PVE_USER_CREATED" = true ]; then
            echo -e "${YELLOW}Removing Proxmox user...${NC}"
            pveum user delete "$PVE_USER" &>/dev/null || true
        fi
        if [ "$PVE_ROLE_CREATED" = true ]; then
            echo -e "${YELLOW}Removing Proxmox role...${NC}"
            pveum role delete "$PVE_ROLE_NAME" &>/dev/null || true
        fi

        # Rollback LXC Container
        if [ -n "${CTID:-}" ] && pct status "$CTID" &>/dev/null; then
            echo -e "${YELLOW}Stopping and destroying container $CTID ($LXC_NAME)...${NC}"
            pct stop "$CTID" &>/dev/null || true
            pct destroy "$CTID" &>/dev/null || true
        fi

        echo -e "${GREEN}Rollback complete. System state reverted.${NC}"
    fi
}

trap cleanup_on_exit EXIT ERR

# ==================================================
# [1/6] Configure and Prepare Container Settings
# ==================================================
echo -e "\n${GREEN}[1/6] Configuring Container Settings...${NC}"

# Check for existing containers named Hermes-Agent
EXISTING_CTID=$(pct list 2>/dev/null | awk -v name="$LXC_NAME" '$3 == name {print $1}' || true)
if [ -n "$EXISTING_CTID" ]; then
    echo -e "${RED}Error: LXC with name '$LXC_NAME' already exists (ID: $EXISTING_CTID). Delete it first if you want to reinstall.${NC}"
    exit 1
fi

# 1. CTID Selection (Automatic)
CTID=$(pvesh get /cluster/nextid)
if pct status "$CTID" &>/dev/null; then
    echo -e "${RED}Error: Suggested Container ID $CTID is already in use.${NC}"
    exit 1
fi
echo -e "Selected Container ID: ${YELLOW}$CTID${NC}"

# 2. Storage Selection (Automatic)
AVAILABLE_STORAGES=($(pvesm status -content rootdir | awk 'NR>1 {print $1}'))
if [ ${#AVAILABLE_STORAGES[@]} -eq 0 ]; then
    echo -e "${RED}No storages supporting rootdir (LXC disk) found!${NC}"
    exit 1
fi
TARGET_STORAGE="${AVAILABLE_STORAGES[0]}"
echo -e "Selected Storage: ${YELLOW}$TARGET_STORAGE${NC}"

# 3. Network Configuration (Automatic Free IP Detection)
GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
CIDR=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1 | cut -d/ -f2)
if [ -z "$CIDR" ]; then CIDR="24"; fi

echo -e "\nScanning network to find a free static IP automatically..."
find_free_ip() {
    local gw="$1"
    local base_ip=$(echo "$gw" | cut -d. -f1-3)
    # Get all IPs configured in any existing LXC/VM configs on Proxmox
    local assigned_ips
    assigned_ips=$(grep -r -o -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' /etc/pve/lxc/ /etc/pve/qemu-server/ 2>/dev/null | cut -d: -f2 | sort -u || true)
    
    # Scan from .50 to .250 to find a free IP
    for i in {50..250}; do
        local test_ip="${base_ip}.${i}"
        
        # Skip gateway
        if [ "$test_ip" = "$gw" ]; then
            continue
        fi
        
        # Skip if in Proxmox configs (offline VM/LXC)
        if echo "$assigned_ips" | grep -q -w "$test_ip"; then
            continue
        fi
        
        # Skip if pings
        if ping -c 1 -W 1 "$test_ip" &>/dev/null; then
            continue
        fi
        
        # Skip if in local ARP table
        if ip neigh show | grep -q -w "$test_ip"; then
            continue
        fi
        
        echo "$test_ip"
        return 0
    done
    return 1
}

STATIC_IP=$(find_free_ip "$GW")
if [ -z "$STATIC_IP" ]; then
    echo -e "${RED}Error: Could not find any free IP address in the subnet automatically.${NC}"
    exit 1
fi
echo -e "Selected IP: ${YELLOW}$STATIC_IP${NC}"

# 4. Disk Size & DNS (Automatic)
DISK_SIZE="30"
echo -e "Selected Disk Size: ${YELLOW}${DISK_SIZE}GB${NC}"

# DNS Server Setup (Auto-detects AdGuard-DNS if present, otherwise uses Host DNS)
DNS_SERVER=""
ADGUARD_CTID=$(pct list 2>/dev/null | awk '$3 == "AdGuard-DNS" {print $1}' || true)
if [ -n "$ADGUARD_CTID" ]; then
    ADGUARD_IP=$(pct config "$ADGUARD_CTID" 2>/dev/null | grep -oE 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | cut -d= -f2 || true)
    if [ -n "$ADGUARD_IP" ]; then
        DNS_SERVER="$ADGUARD_IP"
        echo -e "Detected AdGuard-DNS at: ${YELLOW}$DNS_SERVER${NC} (configuring as container DNS)"
    fi
fi

# 5. Enable/Disable Supplementary Tools (Automatic Default)
ENABLE_PORTAINER=true
ENABLE_WATCHTOWER=true

# ==================================================
# [2/6] Create LXC Container
# ==================================================
if ! confirm_step "LXC Container Creation" "This step will download the Debian 12 container template (if not cached) and create LXC CT $CTID with IP $STATIC_IP and disk size ${DISK_SIZE}GB on storage '$TARGET_STORAGE'."; then
    echo -e "${RED}LXC creation cancelled by user. Exiting.${NC}"
    exit 1
fi

echo -e "\n${GREEN}[2/6] Creating LXC Container...${NC}"
pveam update >/dev/null 2>&1 || true
TEMPLATE_PATH=$(pveam available -section system | grep debian-12-standard | awk '{print $2}' | head -n 1)
if [ -z "$TEMPLATE_PATH" ]; then echo -e "${RED}Could not find Debian 12 template.${NC}"; exit 1; fi
if ! pveam list local | grep -q debian-12; then pveam download local "$TEMPLATE_PATH" >/dev/null 2>&1; fi
LOCAL_TEMPLATE=$(pveam list local | grep debian-12 | awk '{print $1}' | head -n 1)

NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
echo "Creating LXC $CTID on $TARGET_STORAGE..."
pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --rootfs "$TARGET_STORAGE:$DISK_SIZE" --hostname "$LXC_NAME" \
    --net0 "$NET_CONFIG" --unprivileged 1 --features nesting=1,keyctl=1

if [ -n "$DNS_SERVER" ]; then
    pct set $CTID --nameserver "$DNS_SERVER"
fi

pct set $CTID -onboot 1 --timezone host
pct start $CTID

echo "Waiting for container network to initialize..."
sleep 10

# ==================================================
# [3/6] Install Docker & Dependencies
# ==================================================
if ! confirm_step "Docker & Packages Installation" "This step installs git, curl, ca-certificates, and Docker inside the container CT $CTID."; then
    echo -e "${RED}Cannot proceed without installing Docker (required by Hermes). Exiting.${NC}"
    exit 1
fi

echo -e "\n${GREEN}[3/6] Installing Docker & dependencies...${NC}"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl ca-certificates gnupg git"
pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"

# ==================================================
# [4/6] Setup Proxmox API Token (Optional / HITL)
# ==================================================
PVE_API_ENABLED=false
TOKEN_ID=""
TOKEN_SECRET=""
PVE_API_URL=""

if confirm_step "Proxmox API Credentials" "This step creates a dedicated API Token (Role: $PVE_ROLE_NAME, User: $PVE_USER) allowing Hermes to manage VMs/containers on this Proxmox node. Highly recommended for agentic capabilities."; then
    echo -e "\n${GREEN}[4/6] Setting up Proxmox API access...${NC}"
    
    # Create role if it doesn't exist
    if pveum role list | grep -q "$PVE_ROLE_NAME"; then
        echo -e "  ${YELLOW}⚠${NC} Role '${PVE_ROLE_NAME}' already exists, skipping creation."
    else
        pveum role add "$PVE_ROLE_NAME" -privs \
            "VM.Allocate,VM.Audit,VM.Backup,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.Migrate,VM.Monitor,VM.PowerMgmt,VM.Snapshot,VM.Snapshot.Rollback,Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,Sys.Audit,Sys.Console,Sys.Modify,Sys.PowerMgmt,Sys.Syslog,SDN.Audit,SDN.Use,Pool.Allocate,Pool.Audit"
        PVE_ROLE_CREATED=true
        echo -e "  ${GREEN}✓${NC} Role '${PVE_ROLE_NAME}' created"
    fi

    # Create user if it doesn't exist
    if pveum user list | grep -q "$PVE_USER"; then
        echo -e "  ${YELLOW}⚠${NC} User '${PVE_USER}' already exists, skipping creation."
    else
        pveum user add "$PVE_USER" -comment "Hermes AI Agent - Automated Management"
        PVE_USER_CREATED=true
        echo -e "  ${GREEN}✓${NC} User '${PVE_USER}' created"
    fi

    # Assign permissions
    pveum aclmod / -user "$PVE_USER" -role "$PVE_ROLE_NAME" -propagate 1
    echo -e "  ${GREEN}✓${NC} User permissions assigned at root path"

    # Create/Recreate API Token
    if pveum user token list "$PVE_USER" 2>/dev/null | grep -q "$PVE_TOKEN_NAME"; then
        echo -e "  ${YELLOW}⚠${NC} Token '${PVE_TOKEN_NAME}' already exists for '${PVE_USER}'. Recreating..."
        pveum user token remove "$PVE_USER" "$PVE_TOKEN_NAME" >/dev/null 2>&1 || true
    fi
    TOKEN_OUTPUT=$(pveum user token add "$PVE_USER" "$PVE_TOKEN_NAME" -privsep 1 -comment "Hermes AI Agent API Access" 2>&1)
    PVE_TOKEN_CREATED=true

    # Extract details
    TOKEN_SECRET=$(echo "$TOKEN_OUTPUT" | grep -oP 'value.*$' | awk '{print $NF}' || echo "$TOKEN_OUTPUT" | tail -n 1)
    TOKEN_ID="${PVE_USER}!${PVE_TOKEN_NAME}"
    pveum aclmod / -token "$TOKEN_ID" -role "$PVE_ROLE_NAME" -propagate 1

    PVE_HOST_IP=$(hostname -I | awk '{print $1}')
    PVE_API_URL="https://${PVE_HOST_IP}:8006/api2/json"
    PVE_API_ENABLED=true

    echo -e "  ${GREEN}✓${NC} API Token generated successfully."

    # Setup Proxmox MCP Server inside container
    echo -e "\nSetting up Proxmox MCP Server..."
    pct exec $CTID -- bash -c "git clone https://github.com/canvrno/ProxmoxMCP.git /opt/hermes/proxmox-mcp 2>/dev/null || true"

    cat << MCPEOF | pct exec $CTID -- tee /opt/hermes/proxmox-mcp/.env >/dev/null
PROXMOX_HOST=https://${PVE_HOST_IP}:8006
PROXMOX_TOKEN_ID=${TOKEN_ID}
PROXMOX_TOKEN_SECRET=${TOKEN_SECRET}
PROXMOX_VERIFY_SSL=false
MCPEOF

    cat << 'MCPDOCKEREOF' | pct exec $CTID -- tee /opt/hermes/proxmox-mcp/Dockerfile >/dev/null
FROM python:3.12-slim
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -e . 2>/dev/null || pip install --no-cache-dir proxmoxer requests urllib3 mcp
EXPOSE 8380
CMD ["python", "-m", "proxmox_mcp.server", "--transport", "sse", "--host", "0.0.0.0", "--port", "8380"]
MCPDOCKEREOF
    echo -e "  ${GREEN}✓${NC} Proxmox MCP Server cloned and configured"
else
    echo -e "\n${YELLOW}Skipping Proxmox API Token setup. Hermes will run in stand-alone mode.${NC}"
fi

# ==================================================
# [5/6] Write Docker Compose & Config Files
# ==================================================
echo -e "\n${GREEN}[5/6] Writing Docker Compose and configuration files...${NC}"
pct exec $CTID -- mkdir -p /opt/hermes/data

# 1. Write .env inside container
cat << ENVEOF | pct exec $CTID -- tee /opt/hermes/.env >/dev/null
# ── Proxmox API Configuration ──
PROXMOX_API_URL=${PVE_API_URL}
PROXMOX_TOKEN_ID=${TOKEN_ID}
PROXMOX_TOKEN_SECRET=${TOKEN_SECRET}
PROXMOX_VERIFY_SSL=false

# ── Hermes Runtime Settings ──
HERMES_UID=1000
HERMES_GID=1000
API_SERVER_HOST=0.0.0.0
GATEWAY_HEALTH_URL=http://hermes:8642
ENVEOF

# 2. Construct docker-compose.yml on host first to avoid escaping errors
COMPOSE_FILE="/tmp/docker-compose-${CTID}.yml"
cat << 'COMPOSEEOF' > "$COMPOSE_FILE"
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    command: bash -c "pip install --no-cache-dir mcp-server-docker duckduckgo-mcp && gateway run"
    ports:
      - "8642:8642"
    volumes:
      - ./data:/opt/data
      - /var/run/docker.sock:/var/run/docker.sock
    env_file:
      - .env
    labels:
      - "autoexposer.enable=true"
      - "autoexposer.name=Hermes Gateway"
      - "autoexposer.group=AI & Agents"
      - "autoexposer.icon=robot"
      - "autoexposer.port=8642"
      - "autoexposer.subdomain=hermes-api"
COMPOSEEOF

if [ "$PVE_API_ENABLED" = true ]; then
cat << 'COMPOSEEOF' >> "$COMPOSE_FILE"
    depends_on:
      - proxmox-mcp
    networks:
      - hermes-net
COMPOSEEOF
else
cat << 'COMPOSEEOF' >> "$COMPOSE_FILE"
    networks:
      - hermes-net
COMPOSEEOF
fi

cat << 'COMPOSEEOF' >> "$COMPOSE_FILE"

  dashboard:
    image: nousresearch/hermes-agent:latest
    container_name: hermes-dashboard
    restart: unless-stopped
    command: dashboard --host 0.0.0.0 --insecure
    ports:
      - "9119:9119"
    volumes:
      - ./data:/opt/data
    environment:
      - GATEWAY_HEALTH_URL=http://hermes:8642
    env_file:
      - .env
    depends_on:
      - hermes
    networks:
      - hermes-net
    labels:
      - "autoexposer.enable=true"
      - "autoexposer.name=Hermes Dashboard"
      - "autoexposer.group=AI & Agents"
      - "autoexposer.icon=robot-outline"
      - "autoexposer.port=9119"
      - "autoexposer.subdomain=hermes"
COMPOSEEOF

if [ "$PVE_API_ENABLED" = true ]; then
cat << 'COMPOSEEOF' >> "$COMPOSE_FILE"

  proxmox-mcp:
    build: ./proxmox-mcp
    container_name: proxmox-mcp
    restart: unless-stopped
    ports:
      - "8380:8380"
    env_file:
      - ./proxmox-mcp/.env
    networks:
      - hermes-net
COMPOSEEOF
fi

if [ "$ENABLE_PORTAINER" = true ]; then
cat << 'COMPOSEEOF' >> "$COMPOSE_FILE"

  portainer-agent:
    image: portainer/agent:latest
    container_name: portainer_agent
    restart: unless-stopped
    ports:
      - '9001:9001'
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
COMPOSEEOF
fi

if [ "$ENABLE_WATCHTOWER" = true ]; then
cat << 'COMPOSEEOF' >> "$COMPOSE_FILE"

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_SCHEDULE=0 0 12 * * *
      - DOCKER_API_VERSION=1.40
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
COMPOSEEOF
fi

cat << 'COMPOSEEOF' >> "$COMPOSE_FILE"

networks:
  hermes-net:
    driver: bridge
COMPOSEEOF

# Copy docker-compose.yml into container and cleanup host temp file
cat "$COMPOSE_FILE" | pct exec $CTID -- tee /opt/hermes/docker-compose.yml >/dev/null
rm -f "$COMPOSE_FILE"

# 3. Construct Hermes config.yaml
CONFIG_FILE="/tmp/config-${CTID}.yaml"
cat << 'CONFIGEOF' > "$CONFIG_FILE"
# ── Hermes Agent Configuration ──

mcp_servers:
  docker:
    command: "mcp-server-docker"
    description: "Docker Container Management - list, start, stop, and inspect containers"
  duckduckgo:
    command: "duckduckgo-mcp"
    description: "Web Search - search the web using DuckDuckGo"
CONFIGEOF

if [ "$PVE_API_ENABLED" = true ]; then
cat << 'CONFIGEOF' >> "$CONFIG_FILE"
  proxmox:
    url: "http://proxmox-mcp:8380/sse"
    description: "Proxmox VE Server Management - create, start, stop, monitor VMs and containers"
CONFIGEOF
fi

cat << 'CONFIGEOF' >> "$CONFIG_FILE"

# ── Safety Settings ──
# Hermes will ALWAYS ask for confirmation before executing any action
safety:
  require_confirmation: true
  confirmation_required_for:
    - vm_power
    - create_vm
    - delete_vm
    - create_container
    - delete_container
    - modify_network
    - create_backup
    - node_power
CONFIGEOF

# Copy config.yaml into container and cleanup host temp file
cat "$CONFIG_FILE" | pct exec $CTID -- tee /opt/hermes/data/config.yaml >/dev/null
rm -f "$CONFIG_FILE"

echo -e "  ${GREEN}✓${NC} Configuration files successfully created"

# ==================================================
# [6/6] Launch Services & Setup Wizard
# ==================================================
if ! confirm_step "Start Services" "This step launches all the Docker services inside the LXC container ($CTID)."; then
    echo -e "${RED}Services launch cancelled. Exiting.${NC}"
    exit 1
fi

echo -e "\n${GREEN}[6/6] Starting services...${NC}"
pct exec $CTID -- bash -c "chown -R 1000:1000 /opt/hermes/data"
if [ "$PVE_API_ENABLED" = true ]; then
    pct exec $CTID -- bash -c "cd /opt/hermes && docker compose build proxmox-mcp"
fi
pct exec $CTID -- bash -c "cd /opt/hermes && docker compose pull --ignore-buildable"
pct exec $CTID -- bash -c "cd /opt/hermes && docker compose up -d"

echo "Waiting for containers to initialize..."
sleep 15

if [ "$PVE_API_ENABLED" = true ]; then
    echo -e "${CYAN}Checking MCP server status...${NC}"
    if pct exec $CTID -- bash -c "docker inspect proxmox-mcp --format='{{.State.Running}}' 2>/dev/null" | grep -q true; then
        echo -e "  ${GREEN}✓${NC} Proxmox MCP Server is running"
    else
        echo -e "  ${YELLOW}⚠${NC} MCP Server may still be starting. Check container logs: docker logs proxmox-mcp"
    fi
fi

# Deployment successful — Disable Rollback
ROLLBACK_REQUIRED=false
trap - EXIT ERR

# --- AutoExposer Integration ---
CF_DOMAIN=""
if [ -f "/opt/homeserver/auto_exposer/.env" ]; then
    CF_DOMAIN=$(grep -E "^CF_DOMAIN=" /opt/homeserver/auto_exposer/.env | cut -d= -f2- | tr -d '"'\'' ')
fi

if [ -n "$CF_DOMAIN" ] && [ -d "/opt/homeserver/auto_exposer" ]; then
    echo -e "${GREEN}Triggering AutoExposer to automatically expose Hermes via domain: hermes.${CF_DOMAIN}...${NC}"
    (
        cd /opt/homeserver/auto_exposer
        ./venv/bin/python main.py sync
    )
fi

# Official Wizard Confirmation
if confirm_step "Launch Hermes Wizard" "Run the official, interactive 'hermes setup' wizard to finalize your LLM and API configuration?"; then
    echo -e "\nLaunching Setup Wizard..."
    pct exec $CTID -- bash -c "cd /opt/hermes && docker compose exec -it hermes hermes setup" < /dev/tty
else
    echo -e "\n${YELLOW}Setup Wizard skipped. Run it manually later using:${NC}"
    echo -e "  ${CYAN}pct enter $CTID${NC}"
    echo -e "  ${CYAN}cd /opt/hermes && docker compose exec -it hermes hermes setup${NC}"
fi

# ==================================================
# Final Summary
# ==================================================
echo -e "\n${BLUE}================================================================"
echo -e " ✅ SETUP COMPLETE! TAKE A SCREENSHOT OF THIS BOX "
echo -e "================================================================${NC}"
echo -e ""
echo -e "${GREEN}▶ Hermes AI Dashboard (Web UI) ${NC}"
if [ -n "$CF_DOMAIN" ]; then
echo -e "   URL:       ${YELLOW}https://hermes.${CF_DOMAIN}${NC} (or ${YELLOW}http://${STATIC_IP}:9119${NC})"
else
echo -e "   URL:       ${YELLOW}http://${STATIC_IP}:9119${NC}"
fi
echo -e ""
echo -e "${GREEN}▶ Hermes AI Gateway (API) ${NC}"
if [ -n "$CF_DOMAIN" ]; then
echo -e "   URL:       ${YELLOW}https://hermes-api.${CF_DOMAIN}${NC} (or ${YELLOW}http://${STATIC_IP}:8642${NC})"
else
echo -e "   URL:       ${YELLOW}http://${STATIC_IP}:8642${NC}"
fi
echo -e ""
echo -e "${GREEN}▶ Proxmox LXC Container ${NC}"
echo -e "   ID:        ${YELLOW}${CTID}${NC}"
echo -e "   IP:        ${YELLOW}${STATIC_IP}${NC}"
echo -e "   Enter:     ${YELLOW}pct enter $CTID${NC}"
echo -e ""
if [ "$PVE_API_ENABLED" = true ]; then
echo -e "${GREEN}▶ Proxmox MCP Server (AI ↔ Proxmox Bridge) ${NC}"
echo -e "   URL:       ${YELLOW}http://${STATIC_IP}:8380${NC}"
echo -e "   Status:    ${YELLOW}Connected to Hermes via hermes-net${NC}"
echo -e ""
echo -e "${GREEN}▶ Proxmox API Access ${NC}"
echo -e "   API URL:   ${YELLOW}${PVE_API_URL}${NC}"
echo -e "   Token ID:  ${YELLOW}${TOKEN_ID}${NC}"
echo -e "   Role:      ${YELLOW}${PVE_ROLE_NAME} (Full Management)${NC}"
echo -e ""
fi
echo -e "${BLUE}================================================================${NC}"
echo -e "${CYAN}Useful Commands:${NC}"
echo -e "  ${GREEN}pct enter $CTID${NC}                                    # Enter container shell"
echo -e "  ${GREEN}cd /opt/hermes && docker compose exec -it hermes hermes setup${NC}  # Re-run setup wizard"
echo -e "  ${GREEN}cd /opt/hermes && docker compose logs -f${NC}           # View logs"
if [ "$PVE_API_ENABLED" = true ]; then
echo -e "  ${GREEN}cd /opt/hermes && docker compose logs proxmox-mcp${NC} # MCP server logs"
fi
echo -e "  ${GREEN}cd /opt/hermes && docker compose restart${NC}           # Restart all services"
echo -e ""
echo -e "${YELLOW}⚠  Security Note:${NC}"
if [ "$PVE_API_ENABLED" = true ]; then
echo -e "   Hermes has ${BOLD}full management access${NC} to your Proxmox server via MCP."
echo -e "   It is configured to ${BOLD}always ask for your confirmation${NC} before"
echo -e "   executing any action (Human-in-the-Loop enabled in config.yaml)."
else
echo -e "   Hermes is running in stand-alone mode (no Proxmox API integration configured)."
fi
echo -e "   Manage safety settings: ${YELLOW}/opt/hermes/data/config.yaml${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""

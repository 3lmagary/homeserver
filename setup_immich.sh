#!/bin/bash
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)
set -Eeuo pipefail

# ==========================================
# Immich Photo Server (Docker LXC)
# ==========================================

# Note: Telegram integration was intentionally removed for simplicity and privacy.

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo -e "  Immich Photo Server (Docker LXC)"
echo -e "==========================================${NC}"

# Ensure script is run as root (elevate if possible)
if [ "$EUID" -ne 0 ]; then
  if command -v sudo &>/dev/null; then
    echo -e "\033[1;33mThis script needs root privileges. Re-running with sudo...\033[0m"
    if [[ "$0" =~ ^(bash|sh|dash)$ || "$0" == "stdin" || -z "$0" ]]; then
       echo -e "\033[0;31mError: Piped script must be run as root or using: curl -s ... | sudo bash\033[0m"
       exit 1
    else
       exec sudo bash "$0" "$@"
    fi
  else
    echo -e "\033[0;31mError: Please run this script as root (sudo is not installed).\033[0m"
    exit 1
  fi
fi

LXC_NAME="Immich"
EXISTING_CTID=$(pct list 2>/dev/null | awk -v name="$LXC_NAME" '$3 == name {print $1}' || true)

IS_UPDATE=false
ROLLBACK_REQUIRED=true
CTID=""
STATIC_IP=""
DB_PASS=""

if [ -n "$EXISTING_CTID" ]; then
    CTID="$EXISTING_CTID"
    IS_UPDATE=true
    ROLLBACK_REQUIRED=false  # Do not destroy pre-existing container on failure
    echo -e "${YELLOW}LXC container '$LXC_NAME' already exists (ID: $CTID).${NC}"
    echo -e "${GREEN}Updating configuration and applying any changes...${NC}"

    # Start container if not running
    if ! pct status "$CTID" | grep -q "status: running"; then
        echo -e "${YELLOW}Starting container $CTID...${NC}"
        pct start "$CTID"
        sleep 5
    fi

    # Retrieve IP address of existing container
    STATIC_IP=$(pct config $CTID 2>/dev/null | grep "^net0:" | sed -n 's/.*ip=\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/p' || true)
    if [ -z "$STATIC_IP" ]; then
        STATIC_IP=$(pct exec $CTID -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -n 1 || true)
    fi

    # Read existing DB password from .env if it exists
    if pct exec "$CTID" -- test -f /opt/immich/.env 2>/dev/null; then
        DB_PASS_EXISTING=$(pct exec "$CTID" -- grep "^DB_PASSWORD=" /opt/immich/.env | cut -d= -f2- | tr -d '\r')
        if [ -n "$DB_PASS_EXISTING" ]; then
            DB_PASS="$DB_PASS_EXISTING"
        fi
    fi
fi

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
    else
        if [ "$exit_code" -ne 0 ]; then
            echo -e "\n${RED}Error occurred during update. Existing container was NOT destroyed.${NC}"
        fi
    fi
}

trap cleanup_on_exit EXIT ERR

if [ "$IS_UPDATE" = false ]; then
    echo -e "${GREEN}[1/4] Preparing LXC Container...${NC}"
    pveam update >/dev/null 2>&1 || true
    TEMPLATE_PATH=$(pveam available -section system | grep debian-12-standard | awk '{print $2}' | head -n 1)
    if [ -z "$TEMPLATE_PATH" ]; then echo -e "${RED}Could not find Debian 12 template.${NC}"; exit 1; fi
    if ! pveam list local | grep -q debian-12; then pveam download local "$TEMPLATE_PATH" >/dev/null 2>&1; fi
    LOCAL_TEMPLATE=$(pveam list local | grep debian-12 | awk '{print $1}' | head -n 1)

    GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
    CIDR=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1 | cut -d/ -f2)
    if [ -z "$CIDR" ]; then CIDR="24"; fi

    echo -ne "\nScanning network to find a free static IP automatically..."
    find_free_ip() {
        local gw="$1"
        local base_ip=$(echo "$gw" | cut -d. -f1-3)
        local assigned_ips
        assigned_ips=$(grep -r -o -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' /etc/pve/lxc/ /etc/pve/qemu-server/ 2>/dev/null | cut -d: -f2 | sort -u || true)
        local tmp_dir=$(mktemp -d)
        for i in {50..150}; do
            local test_ip="${base_ip}.${i}"
            if [ "$test_ip" = "$gw" ] || (echo "$assigned_ips" | grep -q -w "$test_ip"); then
                continue
            fi
            ( trap '' ERR; ping -c 1 -W 1 "$test_ip" &>/dev/null && touch "${tmp_dir}/${i}" ) &
        done
        wait
        sleep 0.5
        local free_ip=""
        for i in {50..150}; do
            local test_ip="${base_ip}.${i}"
            if [ "$test_ip" = "$gw" ] || (echo "$assigned_ips" | grep -q -w "$test_ip") || [ -f "${tmp_dir}/${i}" ]; then
                continue
            fi
            if ip neigh show 2>/dev/null | grep -q -w "$test_ip"; then
                continue
            fi
            free_ip="$test_ip"
            break
        done
        rm -rf "$tmp_dir"
        if [ -n "$free_ip" ]; then
            echo "$free_ip"
            return 0
        fi
        return 1
    }

    STATIC_IP=$(find_free_ip "$GW" || true)
    if [ -z "$STATIC_IP" ]; then
        echo -e "\n${RED}Error: Could not find any free IP address in the subnet automatically.${NC}"
        exit 1
    fi
    echo -e "Selected IP: ${YELLOW}$STATIC_IP${NC}"

    read -p "Enter Disk Size in GB (default: 20): " DISK_SIZE < /dev/tty
    if [ -z "$DISK_SIZE" ]; then DISK_SIZE="20"; fi

    NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
    TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
    if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

    # Get Next ID
    CTID=$(pvesh get /cluster/nextid)

    # Immich needs at least 2GB RAM for ML models
    echo "Creating Immich LXC $CTID on $TARGET_STORAGE with ${DISK_SIZE}GB disk (2GB RAM for AI models)..."
    pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --rootfs "$TARGET_STORAGE:$DISK_SIZE" --hostname "$LXC_NAME" \
        --net0 "$NET_CONFIG" --unprivileged 1 --features nesting=1,keyctl=1 --memory 2048 --swap 512
    pct set $CTID -onboot 1 --timezone host
    pct start $CTID

    echo "Waiting for network..."
    sleep 15

    echo -e "${GREEN}[2/4] Installing Docker...${NC}"
    pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl wget ca-certificates"
    pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"
else
    echo -e "${GREEN}[1/4] Container exists, verifying network and tools...${NC}"
    # Verify Docker is installed inside container
    if ! timeout 10 pct exec $CTID -- docker --version &>/dev/null; then
        echo -e "${GREEN}Docker not found in existing container. Installing Docker...${NC}"
        pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl wget ca-certificates"
        pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"
    fi
fi

echo -e "${GREEN}[3/4] Downloading Immich config & configuring...${NC}"
pct exec $CTID -- mkdir -p /opt/immich/library

pct exec $CTID -- bash -c "cd /opt/immich && \
    wget -qO docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml"

if ! pct exec "$CTID" -- test -f /opt/immich/.env 2>/dev/null; then
    pct exec $CTID -- bash -c "cd /opt/immich && wget -qO .env https://github.com/immich-app/immich/releases/latest/download/example.env"
fi

if [ -z "$DB_PASS" ]; then
    DB_PASS=$(openssl rand -hex 16)
fi

# Ensure UPLOAD_LOCATION and DB_PASSWORD are set correctly in .env
pct exec $CTID -- bash -c "grep -q '^DB_PASSWORD=' /opt/immich/.env && sed -i 's|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|' /opt/immich/.env || echo 'DB_PASSWORD=${DB_PASS}' >> /opt/immich/.env"
pct exec $CTID -- bash -c "grep -q '^UPLOAD_LOCATION=' /opt/immich/.env && sed -i 's|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=/opt/immich/library|' /opt/immich/.env || echo 'UPLOAD_LOCATION=/opt/immich/library' >> /opt/immich/.env"

# Inject watchtower.enable labels into dynamically downloaded docker-compose.yml for Immich server & machine-learning services
pct exec $CTID -- sed -i '/container_name: immich_server/a \    labels:\n      - "com.centurylinklabs.watchtower.enable=true"' /opt/immich/docker-compose.yml
pct exec $CTID -- sed -i '/container_name: immich_machine_learning/a \    labels:\n      - "com.centurylinklabs.watchtower.enable=true"' /opt/immich/docker-compose.yml

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
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

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
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
EOF

echo -e "${GREEN}[4/4] Starting Immich (this takes 3-5 minutes)...${NC}"
pct exec $CTID -- bash -c "cd /opt/immich && docker compose up -d --remove-orphans"

# Deployment successful - disable rollback
ROLLBACK_REQUIRED=false
trap - EXIT ERR

echo -e "\n${BLUE}=========================================="
echo -e " ✅ Immich Deployed!"
echo -e "==========================================${NC}"
echo -e "Access Immich at: ${YELLOW}http://${STATIC_IP}:2283${NC}"
echo -e "\n${YELLOW}Note: The first startup takes 3-5 minutes."
echo -e "Immich needs to initialize the database and download AI models.${NC}"
echo -e "${YELLOW}Photos are stored at: /opt/immich/library (inside the container)${NC}"
echo -e "\n${YELLOW}Note: Watchtower updates are enabled for Immich core services.${NC}"
echo -e "\n\033[1;32mInfo:\033[0m Telegram integration was intentionally removed for simplicity and privacy."
echo -e ""
echo -e "\033[1;33mNote:\033[0m LXC root password prompt has been removed for better automation."
echo -e "To access this container's shell, run: \033[0;32mpct enter $CTID\033[0m from your Proxmox host."

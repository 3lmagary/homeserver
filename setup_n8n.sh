#!/bin/bash
set -Eeuo pipefail

# ==========================================
# n8n + Evolution API + Postgres Setup
# ==========================================

# Note: Telegram integration was intentionally removed for simplicity and privacy.

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo -e "  n8n + Evolution API + Postgres Setup"
echo -e "==========================================${NC}"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root.${NC}"
  exit 1
fi

# Check if already exists
LXC_NAME="n8n-Server"
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

echo -ne "\nScanning network to find a free static IP automatically..."
find_free_ip() {
    local gw="$1"
    local base_ip=$(echo "$gw" | cut -d. -f1-3)
    local assigned_ips
    assigned_ips=$(grep -r -o -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' /etc/pve/lxc/ /etc/pve/qemu-server/ 2>/dev/null | cut -d: -f2 | sort -u || true)
    local tmp_dir=$(mktemp -d)
    for i in {50..150}; do
        local test_ip="${base_ip}.${i}"
        if [ "$test_ip" = "$gw" ] || echo "$assigned_ips" | grep -q -w "$test_ip"; then
            continue
        fi
        ( ping -c 1 -W 1 "$test_ip" &>/dev/null && touch "${tmp_dir}/${i}" ) &
    done
    sleep 1.2
    local free_ip=""
    for i in {50..150}; do
        local test_ip="${base_ip}.${i}"
        if [ "$test_ip" = "$gw" ] || echo "$assigned_ips" | grep -q -w "$test_ip" || [ -f "${tmp_dir}/${i}" ]; then
            continue
        fi
        if ip neigh show | grep -q -w "$test_ip"; then
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

STATIC_IP=$(find_free_ip "$GW")
if [ -z "$STATIC_IP" ]; then
    echo -e "\n${RED}Error: Could not find any free IP address in the subnet automatically.${NC}"
    exit 1
fi
echo -e "Selected IP: ${YELLOW}$STATIC_IP${NC}"

echo -e "${YELLOW}Generating secure internal database password...${NC}"
DB_PASS=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 24)

PGADMIN_EMAIL=""
PGADMIN_PASS=""

echo -e "\n${YELLOW}Do you want to install pgAdmin? (Database Management UI)${NC}"
echo "Most users don't need this unless they want to manually inspect the database."
read -p "Install pgAdmin? (y/N): " INSTALL_PGADMIN < /dev/tty
if [[ "$INSTALL_PGADMIN" =~ ^[Yy]$ ]]; then
    read -p "Enter an email for pgAdmin Web UI (e.g. admin@example.com): " PGADMIN_EMAIL < /dev/tty
    if [ -z "$PGADMIN_EMAIL" ]; then echo -e "${RED}pgAdmin email cannot be empty.${NC}"; exit 1; fi
    
    read -p "Do you want to auto-generate a secure pgAdmin password? (Y/n): " GEN_PG_PASS < /dev/tty
    GEN_PG_PASS=${GEN_PG_PASS:-"Y"}
    
    if [[ "$GEN_PG_PASS" =~ ^[Yy]$ ]]; then
        PGADMIN_PASS=$(openssl rand -base64 24)
        echo -e "${GREEN}✓ Auto-generated pgAdmin Password: ${YELLOW}$PGADMIN_PASS${NC}"
        echo "pgAdmin Password ($PGADMIN_EMAIL): $PGADMIN_PASS" >> /root/generated-passwords.txt
        chmod 600 /root/generated-passwords.txt
    else
        read -sp "Enter a password for pgAdmin Web UI: " PGADMIN_PASS < /dev/tty; echo
        if [ -z "$PGADMIN_PASS" ]; then echo -e "${RED}pgAdmin password cannot be empty.${NC}"; exit 1; fi
    fi
fi

read -sp "Enter Cloudflare Tunnel Token (leave blank if you don't use it yet): " CF_TOKEN < /dev/tty; echo

EVO_API_KEY=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 24)
echo -e "${YELLOW}Auto-generated Evolution API Key: ${EVO_API_KEY}${NC}"
echo -e "${YELLOW}(Please save this key, you will need it to connect n8n to Evolution API!)${NC}"

read -p "Enter Disk Size in GB (default: 30): " DISK_SIZE < /dev/tty
if [ -z "$DISK_SIZE" ]; then DISK_SIZE="30"; fi

NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

# Get Next ID
CTID=$(pvesh get /cluster/nextid)

echo "Creating n8n LXC $CTID on $TARGET_STORAGE with ${DISK_SIZE}GB disk..."
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
pct exec $CTID -- mkdir -p /opt/n8n/postgres_init

# Create Postgres init script to auto-create multiple databases
pct exec $CTID -- bash -c "cat > /opt/n8n/postgres_init/init-dbs.sql << 'EOF'
CREATE DATABASE evolution_db;
EOF"

# Generate random encryption key for n8n
N8N_ENCRYPTION_KEY=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 32)

# Write .env file (using tee to avoid special character issues)
pct exec $CTID -- bash -c "cat > /opt/n8n/.env << 'ENVEOF'
POSTGRES_USER=n8n_admin
POSTGRES_PASSWORD=$DB_PASS
POSTGRES_DB=n8n_db

PGADMIN_DEFAULT_EMAIL=$PGADMIN_EMAIL
PGADMIN_DEFAULT_PASSWORD=$PGADMIN_PASS

N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
EVO_API_KEY=$EVO_API_KEY
ENVEOF"

# Write docker-compose.yml
cat << EOF | pct exec $CTID -- tee /opt/n8n/docker-compose.yml >/dev/null
services:
  postgres:
    image: postgres:16
    container_name: postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
      - ./postgres_init:/docker-entrypoint-initdb.d
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

$(if [[ "$INSTALL_PGADMIN" =~ ^[Yy]$ ]]; then
echo "  pgadmin:
    image: dpage/pgadmin4
    container_name: pgadmin
    restart: unless-stopped
    environment:
      - PGADMIN_DEFAULT_EMAIL=\${PGADMIN_DEFAULT_EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=\${PGADMIN_DEFAULT_PASSWORD}
    ports:
      - \"5050:80\"
    volumes:
      - ./pgadmin_data:/var/lib/pgadmin
    depends_on:
      postgres:
        condition: service_healthy"
fi)

  n8n:
    image: docker.n8n.io/n8nio/n8n
    container_name: n8n
    restart: unless-stopped
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_USER=\${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - N8N_SECURE_COOKIE=false
    ports:
      - "5678:5678"
    volumes:
      - ./n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy

  redis:
    image: redis:7
    container_name: redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - ./redis_data:/data

  evolution-api:
    image: evoapicloud/evolution-api:latest
    container_name: evolution_api
    restart: unless-stopped
    ports:
      - "8081:8080"
    environment:
      - SERVER_URL=http://${STATIC_IP}:8081
      - AUTHENTICATION_API_KEY=\${EVO_API_KEY}
      - AUTHENTICATION_TYPE=apikey
      - DATABASE_PROVIDER=postgresql
      - DATABASE_CONNECTION_URI=postgresql://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@postgres:5432/evolution_db?schema=public
      - CACHE_REDIS_ENABLED=true
      - CACHE_REDIS_URI=redis://redis:6379
      - CACHE_REDIS_PREFIX_KEY=evo
      - WEBSOCKET_ENABLED=true
      - LOG_LEVEL=ERROR,WARN,INFO
    volumes:
      - ./evolution_instances:/evolution/instances
      - ./evolution_store:/evolution/store
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started

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

if [ -n "$CF_TOKEN" ]; then
cat << EOF | pct exec $CTID -- tee -a /opt/n8n/docker-compose.yml >/dev/null

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=$CF_TOKEN
EOF
fi

echo -e "${GREEN}[4/4] Starting services...${NC}"
# Fix permissions: n8n runs as UID 1000, pgAdmin runs as UID 5050
pct exec $CTID -- bash -c "mkdir -p /opt/n8n/n8n_data && chown -R 1000:1000 /opt/n8n/n8n_data"
if [[ "$INSTALL_PGADMIN" =~ ^[Yy]$ ]]; then
    pct exec $CTID -- bash -c "mkdir -p /opt/n8n/pgadmin_data && chown -R 5050:5050 /opt/n8n/pgadmin_data"
fi
pct exec $CTID -- bash -c "cd /opt/n8n && docker compose up -d"

# Deployment successful - disable rollback
ROLLBACK_REQUIRED=false
trap - EXIT ERR

echo -e "\n${BLUE}================================================================"
echo -e " ✅ SETUP COMPLETE! TAKE A SCREENSHOT OF THIS BOX "
echo -e "================================================================${NC}"
echo -e "${GREEN}▶ n8n (Automation) ${NC}"
echo -e "   - URL:      ${YELLOW}http://${STATIC_IP}:5678${NC}"
echo -e "   - Login:    ${YELLOW}Create any Email & Password on first visit${NC}"
echo -e ""
echo -e "${GREEN}▶ Evolution API (WhatsApp) ${NC}"
echo -e "   - URL:      ${YELLOW}http://${STATIC_IP}:8081${NC}"
echo -e "   - API KEY:  ${YELLOW}${EVO_API_KEY}${NC}  <-- (SAVE THIS FOR n8n!)"
echo -e ""
if [[ "$INSTALL_PGADMIN" =~ ^[Yy]$ ]]; then
echo -e "${GREEN}▶ pgAdmin (Database Manager) ${NC}"
echo -e "   - URL:      ${YELLOW}http://${STATIC_IP}:5050${NC}"
echo -e "   - Email:    ${YELLOW}${PGADMIN_EMAIL}${NC}"
echo -e "   - Password: ${YELLOW}${PGADMIN_PASS}${NC}"
echo -e ""
fi
echo -e "${GREEN}▶ Proxmox LXC Server (SSH/Console) ${NC}"
echo -e "   - IP:       ${YELLOW}${STATIC_IP}${NC}"
echo -e "   - User:     ${YELLOW}root${NC}"
if [ -n "$CF_TOKEN" ]; then
echo -e ""
echo -e "${GREEN}▶ 5. Cloudflare Tunnel ${NC}"
echo -e "   - Status:   ${YELLOW}Active (Go to Cloudflare dashboard to route your domains)${NC}"
fi
echo -e "================================================================"
echo -e "${YELLOW}Note: The internal Postgres password was auto-generated and saved securely.${NC}"
echo -e "\n\033[1;32mInfo:\033[0m Telegram integration was intentionally removed for simplicity and privacy."
echo -e ""
echo -e "\033[1;33mNote:\033[0m LXC root password prompt has been removed for better automation."
echo -e "To access this container's shell, run: \033[0;32mpct enter $CTID\033[0m from your Proxmox host."

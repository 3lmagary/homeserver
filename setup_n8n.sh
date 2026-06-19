#!/bin/bash
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)
set -Eeuo pipefail

# Silence locale warnings
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export LANGUAGE=C.UTF-8

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

DB_PASS=""
PGADMIN_EMAIL=""
PGADMIN_PASS=""
N8N_ENCRYPTION_KEY=""
EVO_API_KEY=""
CF_TOKEN=""
STATIC_IP=""
IS_UPDATE=false
ROLLBACK_REQUIRED=true
CTID=""

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

    
    # Retrieve IP address of existing container from Proxmox configuration directly (much faster)
    STATIC_IP=$(pct config $CTID 2>/dev/null | grep "^net0:" | sed -n 's/.*ip=\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/p' || true)
    if [ -z "$STATIC_IP" ]; then
        STATIC_IP=$(pct exec $CTID -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -n 1 || true)
    fi

    
    # Read existing secrets from container's /opt/n8n/.env using pct exec
    if pct exec "$CTID" -- test -f /opt/n8n/.env 2>/dev/null; then
        echo -e "${GREEN}Reading existing secrets and settings...${NC}"
        EXISTING_ENV=$(pct exec "$CTID" -- cat /opt/n8n/.env 2>/dev/null || true)
        
        # Use existing secrets if found
        DB_PASS_EXISTING=$(echo "$EXISTING_ENV" | grep "^POSTGRES_PASSWORD=" | cut -d= -f2- | tr -d '\r')
        if [ -n "$DB_PASS_EXISTING" ]; then DB_PASS="$DB_PASS_EXISTING"; fi
        
        PGADMIN_EMAIL_EXISTING=$(echo "$EXISTING_ENV" | grep "^PGADMIN_DEFAULT_EMAIL=" | cut -d= -f2- | tr -d '\r')
        if [ -n "$PGADMIN_EMAIL_EXISTING" ]; then PGADMIN_EMAIL="$PGADMIN_EMAIL_EXISTING"; fi
        
        PGADMIN_PASS_EXISTING=$(echo "$EXISTING_ENV" | grep "^PGADMIN_DEFAULT_PASSWORD=" | cut -d= -f2- | tr -d '\r')
        if [ -n "$PGADMIN_PASS_EXISTING" ]; then PGADMIN_PASS="$PGADMIN_PASS_EXISTING"; fi
        
        N8N_ENCRYPTION_KEY_EXISTING=$(echo "$EXISTING_ENV" | grep "^N8N_ENCRYPTION_KEY=" | cut -d= -f2- | tr -d '\r')
        if [ -n "$N8N_ENCRYPTION_KEY_EXISTING" ]; then N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY_EXISTING"; fi
        
        EVO_API_KEY_EXISTING=$(echo "$EXISTING_ENV" | grep "^EVO_API_KEY=" | cut -d= -f2- | tr -d '\r')
        if [ -n "$EVO_API_KEY_EXISTING" ]; then EVO_API_KEY="$EVO_API_KEY_EXISTING"; fi
    fi
    
    # Read existing Cloudflare Tunnel token from compose file
    if pct exec "$CTID" -- test -f /opt/n8n/docker-compose.yml 2>/dev/null; then
        EXISTING_COMPOSE=$(pct exec "$CTID" -- cat /opt/n8n/docker-compose.yml 2>/dev/null || true)
        CF_TOKEN_EXISTING=$(echo "$EXISTING_COMPOSE" | grep -A 10 "cloudflared:" | grep "TUNNEL_TOKEN=" | cut -d= -f2- | tr -d '\r' | head -n 1)
        if [ -z "$CF_TOKEN_EXISTING" ]; then
            CF_TOKEN_EXISTING=$(echo "$EXISTING_COMPOSE" | grep -oP 'TUNNEL_TOKEN=\K\S+' || true)
        fi
        if [ -n "$CF_TOKEN_EXISTING" ]; then CF_TOKEN="$CF_TOKEN_EXISTING"; fi
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
fi

# Retrieve Cloudflare Domain from AutoExposer if configured
CF_DOMAIN=""
if [ -f "/opt/homeserver/auto_exposer/.env" ]; then
    CF_DOMAIN=$(grep -E "^CF_DOMAIN=" /opt/homeserver/auto_exposer/.env | cut -d= -f2- | tr -d '"'\'' ')
fi

if [ -z "$CF_DOMAIN" ]; then
    read -p "Enter your Domain Name (e.g. example.com): " CF_DOMAIN_INPUT < /dev/tty
    CF_DOMAIN=${CF_DOMAIN_INPUT:-"example.com"}
fi

# Ensure secrets are generated if missing or on fresh install
if [ -z "${DB_PASS:-}" ]; then
    echo -e "${YELLOW}Generating secure internal database password...${NC}"
    DB_PASS=$(openssl rand -hex 12)
fi
if [ -z "${N8N_ENCRYPTION_KEY:-}" ]; then
    N8N_ENCRYPTION_KEY=$(openssl rand -hex 16)
fi
if [ -z "${EVO_API_KEY:-}" ]; then
    EVO_API_KEY=$(openssl rand -hex 12)
fi

INSTALL_PGADMIN="n"
if [ "$IS_UPDATE" = true ] && [ -n "$PGADMIN_EMAIL" ]; then
    INSTALL_PGADMIN="y"
    echo -e "${GREEN}✓ pgAdmin is already installed. Keeping existing configuration.${NC}"
else
    DEFAULT_INSTALL_PGADMIN="n"

    echo -e "\n${YELLOW}Do you want to install pgAdmin? (Database Management UI)${NC}"
    echo "Most users don't need this unless they want to manually inspect the database."
    read -p "Install pgAdmin? (y/N) [Default: $DEFAULT_INSTALL_PGADMIN]: " INSTALL_PGADMIN_INPUT < /dev/tty
    INSTALL_PGADMIN_INPUT=${INSTALL_PGADMIN_INPUT:-$DEFAULT_INSTALL_PGADMIN}

    if [[ "$INSTALL_PGADMIN_INPUT" =~ ^[Yy]$ ]]; then
        INSTALL_PGADMIN="y"
        DEFAULT_EMAIL=${PGADMIN_EMAIL:-"3lmagary@gmail.com"}
        read -p "Enter an email for pgAdmin Web UI [Default: $DEFAULT_EMAIL]: " PGADMIN_EMAIL_INPUT < /dev/tty
        PGADMIN_EMAIL=${PGADMIN_EMAIL_INPUT:-$DEFAULT_EMAIL}
        
        if [ -z "$PGADMIN_PASS" ]; then
            read -p "Do you want to auto-generate a secure pgAdmin password? (Y/n): " GEN_PG_PASS < /dev/tty
            GEN_PG_PASS=${GEN_PG_PASS:-"Y"}
            
            if [[ "$GEN_PG_PASS" =~ ^[Yy]$ ]]; then
                # Use hex to prevent any interpolation or special character issues
                PGADMIN_PASS=$(openssl rand -hex 12)
                echo -e "${GREEN}✓ Auto-generated pgAdmin Password: ${YELLOW}$PGADMIN_PASS${NC}"
                echo "pgAdmin Password ($PGADMIN_EMAIL): $PGADMIN_PASS" >> /root/generated-passwords.txt
                chmod 600 /root/generated-passwords.txt
            else
                read -sp "Enter a password for pgAdmin Web UI: " PGADMIN_PASS < /dev/tty; echo
                if [ -z "$PGADMIN_PASS" ]; then echo -e "${RED}pgAdmin password cannot be empty.${NC}"; exit 1; fi
            fi
        fi
    fi
fi

# Ask Cloudflare Tunnel token if empty
if [ -z "$CF_TOKEN" ]; then
    read -sp "Enter Cloudflare Tunnel Token (leave blank if you don't use it yet): " CF_TOKEN_INPUT < /dev/tty; echo
    CF_TOKEN=$CF_TOKEN_INPUT
fi


if [ "$IS_UPDATE" = false ]; then
    read -p "Enter Disk Size in GB (default: 30): " DISK_SIZE < /dev/tty
    if [ -z "$DISK_SIZE" ]; then DISK_SIZE="30"; fi

    NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
    TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
    if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

    # Get Next ID
    CTID=$(pvesh get /cluster/nextid)

    echo "Creating n8n LXC $CTID on $TARGET_STORAGE with ${DISK_SIZE}GB disk..."
    pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --rootfs "$TARGET_STORAGE:$DISK_SIZE" --hostname "$LXC_NAME" \
        --net0 "$NET_CONFIG" --unprivileged 1 --features nesting=1,keyctl=1 --memory 2048 --swap 512
    pct set $CTID -onboot 1 --timezone host

    pct start $CTID

    echo "Waiting for network..."
    sleep 15

    echo -e "${GREEN}[2/4] Installing Docker...${NC}"
    pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl ca-certificates"
    pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"
else
    echo -e "${GREEN}[1/4] Container exists, verifying network and tools...${NC}"
    # Verify Docker is installed inside container
    if ! timeout 10 pct exec $CTID -- docker --version &>/dev/null; then
        echo -e "${GREEN}Docker not found in existing container. Installing Docker...${NC}"
        pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl ca-certificates"
        pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"
    fi

fi


echo -e "${GREEN}[3/4] Writing Docker Compose config...${NC}"
pct exec $CTID -- mkdir -p /opt/n8n/postgres_init

# Create Postgres init script to auto-create multiple databases
pct exec $CTID -- bash -c "cat > /opt/n8n/postgres_init/init-dbs.sql << 'EOF'
CREATE DATABASE evolution_db;
EOF"

# Generate random encryption key for n8n if not set
if [ -z "${N8N_ENCRYPTION_KEY:-}" ]; then
    N8N_ENCRYPTION_KEY=$(openssl rand -hex 16)
fi

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
      - SERVER_URL=https://evolution_api.${CF_DOMAIN}
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
pct exec $CTID -- bash -c "cd /opt/n8n && docker compose up -d --remove-orphans postgres redis"
echo -e "${YELLOW}Waiting for Postgres to be ready to initialize evolution_db...${NC}"
sleep 10
# Ensure evolution_db is created, even if postgres volume already existed from a previous run
pct exec $CTID -- bash -c "docker exec postgres psql -U n8n_admin -d n8n_db -tc \"SELECT 1 FROM pg_database WHERE datname = 'evolution_db'\" | grep -q 1 || docker exec postgres psql -U n8n_admin -d n8n_db -c \"CREATE DATABASE evolution_db;\""

pct exec $CTID -- bash -c "cd /opt/n8n && docker compose up -d --remove-orphans"

# Deployment successful - disable rollback
ROLLBACK_REQUIRED=false
trap - EXIT ERR

# Run AutoExposer Sync if installed and configured to automatically route the domain
if [ -d "/opt/homeserver/auto_exposer" ] && [ -f "/opt/homeserver/auto_exposer/venv/bin/python" ]; then
    echo -e "${GREEN}Running AutoExposer sync to configure Reverse Proxy & SSL DNS...${NC}"
    (cd /opt/homeserver/auto_exposer && ./venv/bin/python main.py sync) || true
fi

echo -e "\n${BLUE}================================================================"
echo -e " ✅ SETUP COMPLETE! TAKE A SCREENSHOT OF THIS BOX "
echo -e "================================================================${NC}"
echo -e "${GREEN}▶ n8n (Automation) ${NC}"
echo -e "   - URL:      ${YELLOW}https://n8n.${CF_DOMAIN}${NC}"
echo -e "   - Login:    ${YELLOW}Create any Email & Password on first visit${NC}"
echo -e ""
echo -e "${GREEN}▶ Evolution API (WhatsApp) ${NC}"
echo -e "   - URL:      ${YELLOW}https://evolution_api.${CF_DOMAIN}${NC}"
echo -e "   - API KEY:  ${YELLOW}${EVO_API_KEY}${NC}  <-- (SAVE THIS FOR n8n!)"
echo -e ""
if [[ "$INSTALL_PGADMIN" =~ ^[Yy]$ ]]; then
echo -e "${GREEN}▶ pgAdmin (Database Manager) ${NC}"
echo -e "   - URL:      ${YELLOW}https://pgadmin.${CF_DOMAIN}${NC}"
echo -e "   - Email:    ${YELLOW}${PGADMIN_EMAIL}${NC}"
echo -e "   - Password: ${YELLOW}${PGADMIN_PASS}${NC}"
echo -e ""
fi
if [ -n "$CF_TOKEN" ]; then
echo -e "${GREEN}▶ Cloudflare Tunnel ${NC}"
echo -e "   - Status:   ${YELLOW}Active (Go to Cloudflare dashboard to route your domains)${NC}"
fi
echo -e "================================================================"


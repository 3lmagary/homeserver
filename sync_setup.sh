#!/bin/bash
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)
set -Eeuo pipefail

# ==========================================
# Proxmox Sync & Backup LXC Setup
# (Syncthing + CoSync + Kopia)
# ==========================================

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BOLD="\033[1m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo " Proxmox Sync LXC (Syncthing + CoSync + Kopia)"
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

LXC_NAME="SyncServer"
EXISTING_CTID=$(pct list 2>/dev/null | awk -v name="$LXC_NAME" '$3 == name {print $1}' || true)
if [ -n "$EXISTING_CTID" ]; then
    echo -e "${YELLOW}LXC '$LXC_NAME' already exists (ID: $EXISTING_CTID). Entering update/migration phase...${NC}"
    CTID="$EXISTING_CTID"
    
    # Start container if it's not running
    if ! pct status "$CTID" 2>/dev/null | grep -q "status: running"; then
        echo -e "${YELLOW}Starting container $CTID...${NC}"
        pct start "$CTID"
        sleep 5
    fi
    
    # Get LXC IP address
    LXC_IP=$(pct exec $CTID -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -n 1)
    
    echo -e "${GREEN}Configuring Docker Compose stack for Syncthing, Kopia & Watchtower...${NC}"
    
    # Extract existing Kopia credentials if available
    EXISTING_USER=$(pct exec $CTID -- grep "\--server-username=" /opt/sync/docker-compose.yml 2>/dev/null | cut -d= -f2 | tr -d '\r\n ' || true)
    EXISTING_REPO_PASS=$(pct exec $CTID -- grep "KOPIA_PASSWORD=" /opt/sync/docker-compose.yml 2>/dev/null | cut -d= -f2 | tr -d '\r\n\x27" ' || true)
    EXISTING_SERVER_PASS=$(pct exec $CTID -- grep "\--server-password=" /opt/sync/docker-compose.yml 2>/dev/null | cut -d= -f2 | tr -d '\r\n\x27" ' || true)
    
    if [ -z "$EXISTING_USER" ] || [ "$EXISTING_USER" = "__KOPIA_USER__" ]; then EXISTING_USER="admin"; fi
    if [ -z "$EXISTING_REPO_PASS" ] || [ "$EXISTING_REPO_PASS" = "__KOPIA_REPO_PASS__" ] || [ "$EXISTING_REPO_PASS" = "__KOPIA_PASS__" ]; then EXISTING_REPO_PASS="admin"; fi
    if [ -z "$EXISTING_SERVER_PASS" ] || [ "$EXISTING_SERVER_PASS" = "__KOPIA_PASS__" ]; then EXISTING_SERVER_PASS="$EXISTING_REPO_PASS"; fi
    
    echo -e "${GREEN}Checking Kopia credentials...${NC}"
    if ! read -p "Do you want to update Kopia Web UI credentials? (y/N): " CHANGE_CREDS; then
        CHANGE_CREDS="n"
    fi
    if [[ "$CHANGE_CREDS" =~ ^[Yy]$ ]]; then
        if ! read -p "Enter new Username for Kopia [default: $EXISTING_USER]: " KOPIA_USER; then
            KOPIA_USER="$EXISTING_USER"
        fi
        if [ -z "$KOPIA_USER" ]; then KOPIA_USER="$EXISTING_USER"; fi
        
        if ! read -p "Enter new Password for Kopia Web UI [default: $EXISTING_SERVER_PASS]: " KOPIA_PASS; then
            KOPIA_PASS="$EXISTING_SERVER_PASS"
        fi
        if [ -z "$KOPIA_PASS" ]; then KOPIA_PASS="$EXISTING_SERVER_PASS"; fi
    else
        KOPIA_USER="$EXISTING_USER"
        KOPIA_PASS="$EXISTING_SERVER_PASS"
    fi
    
    # Repository encryption password must remain unchanged to avoid breaking existing backups!
    KOPIA_REPO_PASS="$EXISTING_REPO_PASS"

    pct exec $CTID -- mkdir -p \
        /opt/sync/configs/syncthing \
        /opt/sync/configs/kopia/config \
        /opt/sync/configs/kopia/cache \
        /opt/sync/configs/kopia/logs \
        /mnt/vault/syncthing \
        /mnt/vault/kopia-snapshots
    
    # Create clean docker-compose.yml
    cat << 'EOF' | pct exec $CTID -- tee /opt/sync/docker-compose.yml > /dev/null
services:
  syncthing:
    image: lscr.io/linuxserver/syncthing:latest
    container_name: syncthing
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Africa/Cairo
    ports:
      - '8384:8384'
      - '22000:22000/tcp'
      - '22000:22000/udp'
      - '21027:21027/udp'
    volumes:
      - /opt/sync/configs/syncthing:/config
      - /mnt/vault/syncthing:/data
    labels:
      - "autoexposer.enable=true"
      - "autoexposer.name=Syncthing"
      - "autoexposer.group=Sync & Backup"
      - "autoexposer.icon=syncthing"
      - "autoexposer.port=8384"

  kopia:
    image: kopia/kopia:latest
    container_name: kopia
    restart: unless-stopped
    hostname: kopia-server
    command:
      - server
      - start
      - --disable-csrf-token-checks
      - --insecure
      - --address=0.0.0.0:51515
      - --server-username=__KOPIA_USER__
      - --server-password=__KOPIA_PASS__
    ports:
      - '51515:51515'
    environment:
      - KOPIA_PASSWORD=__KOPIA_REPO_PASS__
      - TZ=Africa/Cairo
    volumes:
      - /opt/sync/configs/kopia/config:/app/config
      - /opt/sync/configs/kopia/cache:/app/cache
      - /opt/sync/configs/kopia/logs:/app/logs
      - /mnt/vault/syncthing:/data:ro
      - /mnt/vault/kopia-snapshots:/repository
      - /tmp:/tmp:shared
    labels:
      - "autoexposer.enable=true"
      - "autoexposer.name=Kopia"
      - "autoexposer.group=Sync & Backup"
      - "autoexposer.icon=kopia"
      - "autoexposer.port=51515"
      - "autoexposer.advanced_config=location ~ / { client_max_body_size 0; if ($$http_content_type ~* \"application/grpc\") { grpc_pass grpc://__LXC_IP__:51515; } proxy_pass http://__LXC_IP__:51515; }"

  portainer-agent:
    image: portainer/agent:latest
    container_name: portainer_agent
    restart: unless-stopped
    ports:
      - 9001:9001
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

    # Replace placeholders with actual values
    pct exec $CTID -- sed -i "s|__LXC_IP__|$LXC_IP|g" /opt/sync/docker-compose.yml
    pct exec $CTID -- sed -i "s|__KOPIA_USER__|$KOPIA_USER|g" /opt/sync/docker-compose.yml
    pct exec $CTID -- sed -i "s|__KOPIA_PASS__|$KOPIA_PASS|g" /opt/sync/docker-compose.yml
    pct exec $CTID -- sed -i "s|__KOPIA_REPO_PASS__|$KOPIA_REPO_PASS|g" /opt/sync/docker-compose.yml

    # Fix TLS/DNS/MTU issues inside LXC: configure Docker daemon
    pct exec $CTID -- bash -c 'mkdir -p /etc/docker && cat > /etc/docker/daemon.json <<DAEMON
{
  "dns": ["1.1.1.1", "8.8.8.8", "8.8.4.4"],
  "mtu": 1450,
  "max-concurrent-downloads": 1,
  "max-download-attempts": 5
}
DAEMON
systemctl restart docker && sleep 5'

    echo -e "${GREEN}Starting Syncthing & dependencies...${NC}"
    pct exec $CTID -- bash -c '
      cd /opt/sync
      MAX_RETRIES=5
      for attempt in $(seq 1 $MAX_RETRIES); do
        echo "[Pull attempt $attempt/$MAX_RETRIES]"
        if docker compose pull; then
          echo "All images pulled successfully."
          break
        fi
        if [ $attempt -eq $MAX_RETRIES ]; then
          echo "WARNING: Some images failed to pull after $MAX_RETRIES attempts. Starting anyway..."
        else
          echo "Retrying in 15 seconds..."
          sleep 15
        fi
      done
      docker compose up -d --remove-orphans
    '
    
    echo -e "${GREEN}Installing git and deploying CoSync project...${NC}"
    pct exec $CTID -- bash -c "apt-get update && apt-get install -y git"
    
    pct exec $CTID -- bash -c "
      if [ -d '/opt/cosync/.git' ]; then
        echo 'Pulling updates in /opt/cosync...'
        cd /opt/cosync && git fetch origin && git reset --hard origin/main
      else
        echo 'Cloning CoSync repo into /opt/cosync...'
        rm -rf /opt/cosync
        git clone https://github.com/3lmagary/CoSync.git /opt/cosync
      fi
    "
    
    pct exec $CTID -- bash -c "
      if [ ! -f /opt/cosync/.env ]; then
        echo 'Generating secure JWT_SECRET and CONNECTION_CODE in /opt/cosync/.env...'
        SECRET=\$(openssl rand -hex 32)
        CODE=\$(openssl rand -hex 16)
        echo \"JWT_SECRET=\$SECRET\" > /opt/cosync/.env
        echo \"CONNECTION_CODE=\$CODE\" >> /opt/cosync/.env
        echo \"PORT=4000\" >> /opt/cosync/.env
        echo \"DATABASE_PATH=/app/data/sync.db\" >> /opt/cosync/.env
      else
        if ! grep -q "CONNECTION_CODE" /opt/cosync/.env; then
          CODE=\$(openssl rand -hex 16)
          echo \"CONNECTION_CODE=\$CODE\" >> /opt/cosync/.env
        fi
      fi
    "

    echo -e "${GREEN}Starting CoSync docker-compose stack...${NC}"
    pct exec $CTID -- bash -c "cd /opt/cosync && docker compose down 2>/dev/null || true && docker compose up -d --build"
    
    CF_DOMAIN=""
    if [ -f "/opt/homeserver/auto_exposer/.env" ]; then
        CF_DOMAIN=$(grep -E "^CF_DOMAIN=" /opt/homeserver/auto_exposer/.env | cut -d= -f2 | tr -d '\r\n ' || true)
    fi

    LXC_IP=$(pct exec $CTID -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -n 1)

    if [ -n "$CF_DOMAIN" ]; then
        COSYNC_API_URL="https://cosync-api.$CF_DOMAIN"
        SYNCTHING_URL="https://syncthing.$CF_DOMAIN"
        KOPIA_URL="https://kopia.$CF_DOMAIN"
    else
        COSYNC_API_URL="http://$LXC_IP:4000"
        SYNCTHING_URL="http://$LXC_IP:8384"
        KOPIA_URL="http://$LXC_IP:51515"
    fi

    # Trigger autoexposer to register in NPM, Cloudflare and Homepage
    if [ -d "/opt/homeserver/auto_exposer" ]; then
        echo -e "${GREEN}Triggering AutoExposer to register updated services...${NC}"
        (cd /opt/homeserver/auto_exposer && ./venv/bin/python main.py sync) || true
    fi

    CONN_CODE=$(pct exec $CTID -- grep "CONNECTION_CODE" /opt/cosync/.env | cut -d= -f2 | tr -d '\r\n ' || true)

    echo -e "${BLUE}==========================================${NC}"
    echo -e " 🎉 SYNC SERVER MIGRATION COMPLETE!"
    echo -e "${BLUE}==========================================${NC}"
    echo -e "LXC Container ID : $CTID"
    echo -e "IP Address       : ${YELLOW}$LXC_IP${NC}"
    echo -e "CoSync API URL   : ${YELLOW}$COSYNC_API_URL${NC}"
    echo -e "Connection Code  : ${GREEN}$CONN_CODE${NC}"
    echo -e "Syncthing URL    : ${YELLOW}$SYNCTHING_URL${NC}"
    echo -e ""
    echo -e "${GREEN}Kopia Backup Server (Credentials & Connection):${NC}"
    echo -e "  Web UI URL       : ${YELLOW}$KOPIA_URL${NC}"
    echo -e "  Username         : ${GREEN}$KOPIA_USER${NC}"
    echo -e "  Password         : ${GREEN}$KOPIA_PASS${NC}"
    echo -e ""
    echo -e "  ${BOLD}How to connect Kopia Client (App/CLI) to this Server:${NC}"
    echo -e "  - ${BOLD}Remote/Secure Connection:${NC}"
    echo -e "    Use Server URL : ${YELLOW}https://kopia.3lmagary.com:443${NC}"
    echo -e "    (This connects via HTTPS on port 443. Nginx Proxy Manager handles the SSL"
    echo -e "     and forwards the gRPC traffic directly to Kopia on port 51515)."
    echo -e "  - ${BOLD}Local Connection (Inside home network only):${NC}"
    echo -e "    Use Server URL : ${YELLOW}http://$LXC_IP:51515${NC}"
    echo -e "${BLUE}==========================================${NC}"
    exit 0
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

echo -e "${GREEN}[1/4] Storage Selection...${NC}"

OS_BASES=$(lsblk -p -n -l -o NAME,FSTYPE,MOUNTPOINT | awk '$2=="LVM2_member" || $3=="/" || $3=="/boot" || $3=="/boot/efi" {print $1}' | sed -E 's/[0-9]+$//' | sort -u | paste -sd '|' - || true)
EXCLUDE_REGEX="^/dev/loop|^/dev/sr|^/dev/mapper|^/dev/pve|swap"
if [ -n "$OS_BASES" ]; then
    EXCLUDE_REGEX="$EXCLUDE_REGEX|^($OS_BASES)"
fi
SAFE_DEVS=$(lsblk -o NAME,TYPE -p -n -l | grep -vE "$EXCLUDE_REGEX" || true)

mapfile -t DISK_PATHS < <(
    if [ -n "$SAFE_DEVS" ]; then
        echo "$SAFE_DEVS" | while read -r name type; do
            if [ -z "$name" ]; then continue; fi
            if [ "$type" == "disk" ]; then
                if ! echo "$SAFE_DEVS" | grep -qE "^${name}[0-9a-zA-Z]+"; then
                    echo "$name"
                fi
            else
                echo "$name"
            fi
        done | sort
    fi
)

if [ ${#DISK_PATHS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No extra drives found. We will use the default LXC storage.${NC}"
    USE_EXTRA_DISK="no"
else
    echo -e "\n${YELLOW}Available Disks/Partitions for Syncthing Data:${NC}"
    echo "[0] Skip - Use default LXC internal storage only"
    i=1
    for disk in "${DISK_PATHS[@]}"; do
        D_SIZE=$(lsblk -o SIZE -n -d "$disk" 2>/dev/null | tr -d ' ' || echo "Unknown")
        D_FSTYPE=$(blkid -s TYPE -o value "$disk" 2>/dev/null || echo "Unknown/None")
        D_MODEL=$(lsblk -o MODEL -n -d "$disk" 2>/dev/null | xargs || echo "Unknown")
        echo "[$i] $disk (Size: $D_SIZE, Format: $D_FSTYPE, Model: $D_MODEL)"
        ((i++))
    done
    if ! read -p "Enter the number of the drive you want to use [Default: 0]: " DISK_NUM; then
        DISK_NUM="0"
    fi
    if [ "${DISK_NUM:-0}" == "0" ]; then
        USE_EXTRA_DISK="no"
    elif [[ "$DISK_NUM" =~ ^[0-9]+$ ]] && [ "$DISK_NUM" -le "${#DISK_PATHS[@]}" ]; then
        USE_EXTRA_DISK="yes"
        SELECTED_DISK="${DISK_PATHS[$((DISK_NUM-1))]}"
    else
        USE_EXTRA_DISK="no"
    fi
fi

if [ "$USE_EXTRA_DISK" == "yes" ]; then
    FS_TYPE=$(blkid -s TYPE -o value "$SELECTED_DISK" 2>/dev/null || true)
    if [ "$FS_TYPE" == "ext4" ] || [ "$FS_TYPE" == "xfs" ] || [ "$FS_TYPE" == "btrfs" ]; then
        echo -e "${GREEN}Drive is formatted as $FS_TYPE.${NC}"
    else
        if [ -z "$FS_TYPE" ]; then
            echo -e "${YELLOW}Warning: This drive has no known filesystem (unformatted).${NC}"
        else
            echo -e "${YELLOW}Warning: This drive is currently formatted as $FS_TYPE.${NC}"
        fi
        if ! read -p "Do you want to WIPE THIS ENTIRE DRIVE and format it to ext4? (y/N): " FORMAT_CHOICE; then
            FORMAT_CHOICE="n"
        fi
        if [[ "$FORMAT_CHOICE" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Formatting $SELECTED_DISK to ext4...${NC}"
            mkfs.ext4 -F "$SELECTED_DISK"
            FS_TYPE="ext4"
        fi
    fi

    UUID=$(blkid -s UUID -o value "$SELECTED_DISK" 2>/dev/null || true)
    if [ -z "$UUID" ]; then
        echo -e "${RED}Could not read UUID. Cannot proceed with mounting.${NC}"
        exit 1
    fi
    EXISTING_MOUNT=$(awk -v uuid="$UUID" '$1=="UUID="uuid {print $2}' /etc/fstab || true)
    if [ -n "$EXISTING_MOUNT" ]; then
        MOUNT_DIR="$EXISTING_MOUNT"
        echo -e "${YELLOW}Drive already mounted at $MOUNT_DIR.${NC}"
    else
        if ! read -p "Drive Name (e.g. SyncDrive) [Default: SyncDrive]: " DRIVE_NAME; then
            DRIVE_NAME="SyncDrive"
        fi
        if [ -z "$DRIVE_NAME" ]; then DRIVE_NAME="SyncDrive"; fi
        DRIVE_NAME=$(echo "$DRIVE_NAME" | tr ' ' '_')
        MOUNT_DIR="/mnt/$DRIVE_NAME"
        mkdir -p "$MOUNT_DIR"
        echo "Adding drive to /etc/fstab..."
        if [ "$FS_TYPE" == "ntfs" ]; then
            echo "UUID=$UUID $MOUNT_DIR ntfs-3g defaults,uid=1000,gid=1000,dmask=022,fmask=133 0 0" >> /etc/fstab
        elif [ "$FS_TYPE" == "ext4" ]; then
            echo "UUID=$UUID $MOUNT_DIR ext4 defaults 0 2" >> /etc/fstab
        else
            echo "UUID=$UUID $MOUNT_DIR auto defaults 0 0" >> /etc/fstab
        fi
        systemctl daemon-reload
    fi
    mount -a || true
fi

echo -e "\n${GREEN}[2/4] Preparing LXC Configuration...${NC}"

# Get Next ID
CTID=$(pvesh get /cluster/nextid)
pveam update >/dev/null 2>&1 || true
TEMPLATE_PATH=$(pveam available -section system | grep debian-12-standard | awk '{print $2}' | head -n 1)
if [ -z "$TEMPLATE_PATH" ]; then echo -e "${RED}Could not find Debian 12 template.${NC}"; exit 1; fi
if ! pveam list local | grep -q debian-12; then
    pveam download local "$TEMPLATE_PATH" >/dev/null 2>&1
fi
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

STATIC_IP=$(find_free_ip "$GW" || true)
if [ -z "$STATIC_IP" ]; then
    echo -e "\n${YELLOW}Warning: Could not detect a free IP automatically.${NC}"
    if ! read -p "Please enter a static IP for the container (e.g. 192.168.0.101): " STATIC_IP; then
        STATIC_IP=""
    fi
    if [ -z "$STATIC_IP" ]; then
        echo -e "${RED}Error: Static IP is required to proceed.${NC}"
        exit 1
    fi
fi
echo -e "Selected IP: ${YELLOW}$STATIC_IP${NC}"
NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW},mtu=1450"

TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

# Disk size selection - defaults to 20GB for sufficient space for system + configs + local backups
if ! read -p "Enter Disk Size in GB for Sync LXC (default: 20): " DISK_SIZE; then
    DISK_SIZE="20"
fi
if [ -z "$DISK_SIZE" ]; then DISK_SIZE="20"; fi
if ! [[ "$DISK_SIZE" =~ ^[0-9]+$ ]]; then echo -e "${RED}Disk size must be a number.${NC}"; exit 1; fi

# Prompt for Kopia credentials
if ! read -p "Enter Username for Kopia backup server [default: admin]: " KOPIA_USER; then
    KOPIA_USER="admin"
fi
if [ -z "$KOPIA_USER" ]; then KOPIA_USER="admin"; fi

if ! read -p "Enter Password for Kopia backup server: " KOPIA_PASS; then
    KOPIA_PASS=""
fi
while [ -z "$KOPIA_PASS" ]; do
    if ! read -p "Password cannot be empty. Enter Password for Kopia: " KOPIA_PASS; then
        KOPIA_PASS=""
        break
    fi
done

echo -e "${GREEN}[3/4] Creating LXC Container $CTID with ${DISK_SIZE}GB disk...${NC}"
pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --rootfs "$TARGET_STORAGE:${DISK_SIZE}" --hostname "$LXC_NAME" --net0 $NET_CONFIG \
    --unprivileged 1 --features nesting=1,keyctl=1

if [ "$USE_EXTRA_DISK" == "yes" ]; then
    echo "Binding $MOUNT_DIR to LXC..."
    pct set $CTID -mp0 "$MOUNT_DIR,mp=/mnt/vault"
fi

pct set $CTID -onboot 1
pct start $CTID
sleep 15

echo -e "${GREEN}[4/4] Installing Docker and Services...${NC}"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl ca-certificates"
pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"

# Fix TLS/DNS/MTU issues inside LXC: configure Docker daemon
pct exec $CTID -- bash -c 'mkdir -p /etc/docker && cat > /etc/docker/daemon.json <<DAEMON
{
  "dns": ["1.1.1.1", "8.8.8.8", "8.8.4.4"],
  "mtu": 1450,
  "max-concurrent-downloads": 1,
  "max-download-attempts": 5
}
DAEMON
systemctl restart docker && sleep 5'

echo "Configuring Docker Compose stack..."
pct exec $CTID -- mkdir -p \
    /opt/sync/configs/syncthing \
    /opt/sync/configs/kopia/config \
    /opt/sync/configs/kopia/cache \
    /opt/sync/configs/kopia/logs \
    /mnt/vault/syncthing \
    /mnt/vault/kopia-snapshots

# Create docker-compose.yml
cat << 'EOF' | pct exec $CTID -- tee /opt/sync/docker-compose.yml >/dev/null
services:
  syncthing:
    image: lscr.io/linuxserver/syncthing:latest
    container_name: syncthing
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Africa/Cairo
    ports:
      - '8384:8384'
      - '22000:22000/tcp'
      - '22000:22000/udp'
      - '21027:21027/udp'
    volumes:
      - /opt/sync/configs/syncthing:/config
      - /mnt/vault/syncthing:/data
    labels:
      - "autoexposer.enable=true"
      - "autoexposer.name=Syncthing"
      - "autoexposer.group=Sync & Backup"
      - "autoexposer.icon=syncthing"
      - "autoexposer.port=8384"

  kopia:
    image: kopia/kopia:latest
    container_name: kopia
    restart: unless-stopped
    hostname: kopia-server
    command:
      - server
      - start
      - --disable-csrf-token-checks
      - --insecure
      - --address=0.0.0.0:51515
      - --server-username=__KOPIA_USER__
      - --server-password=__KOPIA_PASS__
    ports:
      - '51515:51515'
    environment:
      - KOPIA_PASSWORD=__KOPIA_PASS__
      - TZ=Africa/Cairo
    volumes:
      - /opt/sync/configs/kopia/config:/app/config
      - /opt/sync/configs/kopia/cache:/app/cache
      - /opt/sync/configs/kopia/logs:/app/logs
      - /mnt/vault/syncthing:/data:ro
      - /mnt/vault/kopia-snapshots:/repository
      - /tmp:/tmp:shared
    labels:
      - "autoexposer.enable=true"
      - "autoexposer.name=Kopia"
      - "autoexposer.group=Sync & Backup"
      - "autoexposer.icon=kopia"
      - "autoexposer.port=51515"
      - "autoexposer.advanced_config=location ~ / { client_max_body_size 0; if ($$http_content_type ~* \"application/grpc\") { grpc_pass grpc://__LXC_IP__:51515; } proxy_pass http://__LXC_IP__:51515; }"

  portainer-agent:
    image: portainer/agent:latest
    container_name: portainer_agent
    restart: unless-stopped
    ports:
      - 9001:9001
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

# Replace placeholders with actual values
pct exec $CTID -- sed -i "s|__LXC_IP__|$STATIC_IP|g" /opt/sync/docker-compose.yml
pct exec $CTID -- sed -i "s|__KOPIA_USER__|$KOPIA_USER|g" /opt/sync/docker-compose.yml
pct exec $CTID -- sed -i "s|__KOPIA_PASS__|$KOPIA_PASS|g" /opt/sync/docker-compose.yml

echo "Starting Docker Compose..."
# Pull images with retry
pct exec $CTID -- bash -c '
  cd /opt/sync
  MAX_RETRIES=5
  for attempt in $(seq 1 $MAX_RETRIES); do
    echo "[Pull attempt $attempt/$MAX_RETRIES]"
    if docker compose pull; then
      echo "All images pulled successfully."
      break
    fi
    if [ $attempt -eq $MAX_RETRIES ]; then
      echo "WARNING: Some images failed to pull after $MAX_RETRIES attempts. Starting anyway..."
    else
      echo "Retrying in 15 seconds..."
      sleep 15
    fi
  done
  docker compose up -d
'

echo "Installing git and deploying CoSync project..."
pct exec $CTID -- bash -c "apt-get update && apt-get install -y git"
pct exec $CTID -- bash -c "rm -rf /opt/cosync && git clone https://github.com/3lmagary/CoSync.git /opt/cosync"

pct exec $CTID -- bash -c "
  if [ ! -f /opt/cosync/.env ]; then
    echo 'Generating secure JWT_SECRET and CONNECTION_CODE in /opt/cosync/.env...'
    SECRET=\$(openssl rand -hex 32)
    CODE=\$(openssl rand -hex 16)
    echo \"JWT_SECRET=\$SECRET\" > /opt/cosync/.env
    echo \"CONNECTION_CODE=\$CODE\" >> /opt/cosync/.env
    echo \"PORT=4000\" >> /opt/cosync/.env
    echo \"DATABASE_PATH=/app/data/sync.db\" >> /opt/cosync/.env
  else
    if ! grep -q "CONNECTION_CODE" /opt/cosync/.env; then
      CODE=\$(openssl rand -hex 16)
      echo \"CONNECTION_CODE=\$CODE\" >> /opt/cosync/.env
    fi
  fi
"

echo "Starting CoSync docker-compose stack..."
pct exec $CTID -- bash -c "cd /opt/cosync && docker compose up -d --build"

# Deployment successful - disable rollback
ROLLBACK_REQUIRED=false
trap - EXIT ERR

CF_DOMAIN=""
if [ -f "/opt/homeserver/auto_exposer/.env" ]; then
    CF_DOMAIN=$(grep -E "^CF_DOMAIN=" /opt/homeserver/auto_exposer/.env | cut -d= -f2 | tr -d '\r\n ' || true)
fi

LXC_IP=$(pct exec $CTID -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -n 1)

if [ -n "$CF_DOMAIN" ]; then
    COSYNC_API_URL="https://cosync-api.$CF_DOMAIN"
    SYNCTHING_URL="https://syncthing.$CF_DOMAIN"
    KOPIA_URL="https://kopia.$CF_DOMAIN"
else
    COSYNC_API_URL="http://$LXC_IP:4000"
    SYNCTHING_URL="http://$LXC_IP:8384"
    KOPIA_URL="http://$LXC_IP:51515"
fi

# Trigger autoexposer to register in NPM, Cloudflare and Homepage
if [ -d "/opt/homeserver/auto_exposer" ]; then
    echo -e "${GREEN}Triggering AutoExposer to register CoSync & Syncthing...${NC}"
    (cd /opt/homeserver/auto_exposer && ./venv/bin/python main.py sync) || true
fi

CONN_CODE=$(pct exec $CTID -- grep "CONNECTION_CODE" /opt/cosync/.env | cut -d= -f2 | tr -d '\r\n ' || true)

echo -e "${BLUE}================================================================"
echo -e " 🎉 SYNC & BACKUP SERVER IS READY!"
echo -e "================================================================${NC}"
echo -e "LXC Container ID : $CTID"
echo -e "IP Address       : ${YELLOW}$LXC_IP${NC}"
if [ "$USE_EXTRA_DISK" == "yes" ]; then
    echo -e "Storage Layout   :"
    echo -e "  ${YELLOW}/mnt/vault/syncthing/${NC}        → Syncthing sync folders (use this path in Syncthing UI)"
    echo -e "  ${YELLOW}/mnt/vault/kopia-snapshots/${NC}  → Kopia backup repository"
fi
echo -e ""
echo -e "${GREEN}1) CoSync API (Obsidian Headless Sync)${NC}"
echo -e "   Server URL      : ${YELLOW}$COSYNC_API_URL${NC}"
echo -e "   Connection Code : ${GREEN}$CONN_CODE${NC}"
echo -e ""
echo -e "${GREEN}2) Syncthing (File Sync & Backups)${NC}"
echo -e "   URL             : ${YELLOW}$SYNCTHING_URL${NC}"
if [ "$USE_EXTRA_DISK" == "yes" ]; then
    echo -e "   -> Add folders in Syncthing UI using path: /data/YourFolderName"
else
    echo -e "   -> Add folders in Syncthing UI using path: /data"
fi
echo -e ""
echo -e "${GREEN}3) Kopia (Snapshot & Incremental Backup)${NC}"
echo -e "   Web UI URL      : ${YELLOW}$KOPIA_URL${NC}"
echo -e "   Username        : ${GREEN}$KOPIA_USER${NC}"
echo -e "   Password        : ${GREEN}$KOPIA_PASS${NC}"
echo -e "   Repository      : /mnt/vault/kopia-snapshots (inside LXC)"
echo -e "   Source Data     : /data → points to /mnt/vault/syncthing"
echo -e ""
echo -e "   ${BOLD}How to connect Kopia Client (App/CLI) to this Server:${NC}"
echo -e "   - ${BOLD}Remote/Secure Connection:${NC}"
echo -e "     Use Server URL : ${YELLOW}https://kopia.3lmagary.com:443${NC}"
echo -e "     (Connects via HTTPS port 443. Nginx Proxy Manager terminates SSL and"
echo -e "      routes the gRPC traffic to Kopia on port 51515)."
echo -e "   - ${BOLD}Local Connection (Inside home network only):${NC}"
echo -e "     Use Server URL : ${YELLOW}http://$LXC_IP:51515${NC}"
echo -e ""
echo -e "${YELLOW}To configure Obsidian:${NC}"
echo -e " 1. Install 'Obsidian CoSync' plugin."
echo -e " 2. In plugin settings, enter Server URL: $COSYNC_API_URL"
echo -e " 3. Enter Connection Code: $CONN_CODE"
echo -e " 4. Enter Device Name (e.g. PC, Phone, Tablet) to show who is editing"
echo -e "${BLUE}================================================================${NC}"
echo -e "  [+] Syncthing + CoSync + Kopia + Portainer Agent + Watchtower"
echo -e "  [+] AutoExposer Labels configured for all services"
echo -e "${BLUE}================================================================${NC}"

echo -e ""
echo -e "\033[1;33mNote:\033[0m LXC root password prompt has been removed for better automation."
echo -e "To access this container's shell, run: \033[0;32mpct enter $CTID\033[0m from your Proxmox host."

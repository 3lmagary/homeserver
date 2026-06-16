#!/bin/bash
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)
set -Eeuo pipefail

# ==========================================
# Proxmox Sync & Backup LXC Setup
# (Syncthing + CouchDB for Obsidian LiveSync)
# ==========================================

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo " Proxmox Sync LXC (Syncthing + CouchDB)"
echo -e "==========================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root.${NC}"
  exit 1
fi

LXC_NAME="SyncServer"
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
    read -p "Enter the number of the drive you want to use [Default: 0]: " DISK_NUM < /dev/tty
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
        read -p "Do you want to WIPE THIS ENTIRE DRIVE and format it to ext4? (y/N): " FORMAT_CHOICE < /dev/tty
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
        read -p "Drive Name (e.g. SyncDrive) [Default: SyncDrive]: " DRIVE_NAME < /dev/tty
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

read -p "Do you want to auto-generate a secure CouchDB/Syncthing Password? (Y/n): " GEN_CHOICE < /dev/tty
GEN_CHOICE=${GEN_CHOICE:-"Y"}

if [[ "$GEN_CHOICE" =~ ^[Yy]$ ]]; then
    SYNC_PASS=$(openssl rand -base64 24)
    echo -e "${GREEN}✓ Auto-generated Password: ${YELLOW}$SYNC_PASS${NC}"
    echo "CouchDB & Syncthing Admin Password: $SYNC_PASS" >> /root/generated-passwords.txt
    chmod 600 /root/generated-passwords.txt
else
    read -sp "Enter a password for the 'admin' user: " SYNC_PASS < /dev/tty; echo
    if [ -z "$SYNC_PASS" ]; then
        echo -e "${RED}Password cannot be empty. Defaulting to 'admin'.${NC}"
        SYNC_PASS="admin"
    fi
fi

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

STATIC_IP=$(find_free_ip "$GW")
if [ -z "$STATIC_IP" ]; then
    echo -e "\n${RED}Error: Could not find any free IP address in the subnet automatically.${NC}"
    exit 1
fi
echo -e "Selected IP: ${YELLOW}$STATIC_IP${NC}"
NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"

TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

echo -e "${GREEN}[3/4] Creating LXC Container $CTID...${NC}"
pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --hostname "$LXC_NAME" --net0 $NET_CONFIG \
    --unprivileged 1 --features nesting=1,keyctl=1

if [ "$USE_EXTRA_DISK" == "yes" ]; then
    echo "Binding $MOUNT_DIR to LXC..."
    pct set $CTID -mp0 "$MOUNT_DIR,mp=/mnt/sync_data"
fi

pct set $CTID -onboot 1
pct start $CTID
sleep 15

echo -e "${GREEN}[4/4] Installing Docker and Services...${NC}"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl ca-certificates"
pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh"

echo "Configuring Docker Compose stack..."
pct exec $CTID -- mkdir -p /opt/sync/couchdb
pct exec $CTID -- mkdir -p /opt/sync/syncthing
pct exec $CTID -- mkdir -p /mnt/sync_data

# Create CouchDB CORS config restricted for security
pct exec $CTID -- bash -c "cat << 'EOF' > /opt/sync/couchdb/cors.ini
[httpd]
enable_cors = true

[cors]
origins = app://obsidian.md, capacitor://localhost, http://localhost, http://127.0.0.1
credentials = true
methods = GET, PUT, POST, HEAD, DELETE
headers = accept, authorization, content-type, origin, referer, x-csrf-token

[chttpd]
max_document_size = 50000000
EOF"

# Fix CouchDB permissions (UID 5984 is used by CouchDB inside the container)
pct exec $CTID -- chown -R 5984:5984 /opt/sync/couchdb

# Create docker-compose.yml
cat << EOF | pct exec $CTID -- tee /opt/sync/docker-compose.yml >/dev/null
services:
  couchdb:
    image: couchdb:latest
    container_name: couchdb
    restart: unless-stopped
    ports:
      - '5984:5984'
    environment:
      - COUCHDB_USER=admin
      - COUCHDB_PASSWORD=$SYNC_PASS
    volumes:
      - ./couchdb/data:/opt/couchdb/data
      - ./couchdb/cors.ini:/opt/couchdb/etc/local.d/cors.ini:ro
    labels:
      - "autoexposer.enable=true"
      - "autoexposer.name=CouchDB"
      - "autoexposer.group=Sync & Backup"
      - "autoexposer.icon=couchdb"
      - "autoexposer.port=5984"

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
      - ./syncthing/config:/config
      - /mnt/sync_data:/data1
    labels:
      - "autoexposer.enable=true"
      - "autoexposer.name=Syncthing"
      - "autoexposer.group=Sync & Backup"
      - "autoexposer.icon=syncthing"
      - "autoexposer.port=8384"

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

echo "Starting Docker Compose..."
pct exec $CTID -- bash -c "cd /opt/sync && docker compose up -d"

# Deployment successful - disable rollback
ROLLBACK_REQUIRED=false
trap - EXIT ERR

LXC_IP=$(pct exec $CTID -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -n 1)

echo -e "${BLUE}=========================================="
echo -e " 🎉 SYNC SERVER IS READY (Docker Edition)!"
echo -e "==========================================${NC}"
echo -e "LXC Container ID : $CTID"
echo -e "IP Address       : ${YELLOW}$LXC_IP${NC}"
if [ "$USE_EXTRA_DISK" == "yes" ]; then
    echo -e "Storage Bound to : ${YELLOW}/mnt/sync_data${NC} (mapped inside Syncthing to /data1)"
fi
echo -e ""
echo -e "${GREEN}1) Syncthing (Backups & File Sync)${NC}"
echo -e "URL: ${YELLOW}http://$LXC_IP:8384${NC}"
if [ "$USE_EXTRA_DISK" == "yes" ]; then
    echo -e "   -> When adding a folder in Syncthing, set its path to: /data1/YourFolderName"
else
    echo -e "   -> When adding a folder in Syncthing, set its path to: /data1"
fi
echo -e ""
echo -e "${GREEN}2) CouchDB (Obsidian LiveSync)${NC}"
echo -e "URL: ${YELLOW}http://$LXC_IP:5984/_utils/${NC}"
echo -e "Username: admin"
echo -e "Password: $SYNC_PASS"
if [[ "$GEN_CHOICE" =~ ^[Yy]$ ]]; then
echo -e "Note:     ${GREEN}Saved to /root/generated-passwords.txt on host${NC}"
fi
echo -e ""
echo -e "${YELLOW}To configure Obsidian:${NC}"
echo -e " 1. Install 'Self-hosted LiveSync' plugin."
echo -e " 2. In plugin settings, enter URI: http://$LXC_IP:5984"
echo -e " 3. Username: admin / Password: $SYNC_PASS"
echo -e " 4. Database Name: obsidian"
echo -e " 5. Click 'Test' and then 'Check Database'. It will create the DB automatically."
echo -e "${BLUE}==========================================${NC}"
echo -e "  [+] Included Portainer Agent & Watchtower"
echo -e "  [+] Included AutoExposer Labels"
echo -e "  [+] CouchDB CORS Restricted to Obsidian schema and local origins"
echo -e "${BLUE}==========================================${NC}"
echo -e ""
echo -e "\033[1;33mNote:\033[0m LXC root password prompt has been removed for better automation."
echo -e "To access this container's shell, run: \033[0;32mpct enter $CTID\033[0m from your Proxmox host."

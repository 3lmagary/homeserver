#!/bin/bash

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

echo -e "${GREEN}[1/4] Storage Selection...${NC}"

OS_BASES=$(lsblk -p -n -l -o NAME,FSTYPE,MOUNTPOINT | awk '$2=="LVM2_member" || $3=="/" || $3=="/boot" || $3=="/boot/efi" {print $1}' | sed -E 's/[0-9]+$//' | sort -u | paste -sd '|' -)
EXCLUDE_REGEX="^/dev/loop|^/dev/sr|^/dev/mapper|^/dev/pve|swap"
if [ -n "$OS_BASES" ]; then
    EXCLUDE_REGEX="$EXCLUDE_REGEX|^($OS_BASES)"
fi
SAFE_DEVS=$(lsblk -o NAME,TYPE -p -n -l | grep -vE "$EXCLUDE_REGEX")
mapfile -t DISK_PATHS < <(
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
)

if [ ${#DISK_PATHS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No extra drives found. We will use the default LXC storage.${NC}"
    USE_EXTRA_DISK="no"
else
    echo -e "\n${YELLOW}Available Disks/Partitions for Syncthing Data:${NC}"
    echo "[0] Skip - Use default LXC internal storage only"
    i=1
    for disk in "${DISK_PATHS[@]}"; do
        D_SIZE=$(lsblk -o SIZE -n -d "$disk" 2>/dev/null | tr -d ' ')
        D_FSTYPE=$(blkid -s TYPE -o value "$disk" 2>/dev/null || echo "Unknown/None")
        D_MODEL=$(lsblk -o MODEL -n -d "$disk" 2>/dev/null | xargs)
        echo "[$i] $disk (Size: $D_SIZE, Format: $D_FSTYPE, Model: $D_MODEL)"
        ((i++))
    done
    read -p "Enter the number of the drive you want to use [Default: 0]: " DISK_NUM < /dev/tty
    if [ "$DISK_NUM" == "0" ] || [ -z "$DISK_NUM" ]; then
        USE_EXTRA_DISK="no"
    elif [[ "$DISK_NUM" =~ ^[0-9]+$ ]] && [ "$DISK_NUM" -le "${#DISK_PATHS[@]}" ]; then
        USE_EXTRA_DISK="yes"
        SELECTED_DISK="${DISK_PATHS[$((DISK_NUM-1))]}"
    else
        USE_EXTRA_DISK="no"
    fi
fi

if [ "$USE_EXTRA_DISK" == "yes" ]; then
    FS_TYPE=$(blkid -s TYPE -o value "$SELECTED_DISK" || true)
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

    UUID=$(blkid -s UUID -o value "$SELECTED_DISK")
    EXISTING_MOUNT=$(awk -v uuid="$UUID" '$1=="UUID="uuid {print $2}' /etc/fstab)
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

SYNC_USER=${SUDO_USER:-admin}
if [ "$SYNC_USER" == "root" ]; then SYNC_USER="admin"; fi

read -p "Enter a password for user ($SYNC_USER) [Used for CouchDB & Syncthing]: " SYNC_PASS < /dev/tty
if [ -z "$SYNC_PASS" ]; then
    echo -e "${RED}Password cannot be empty. Defaulting to 'admin'.${NC}"
    SYNC_PASS="admin"
fi

CTID=$(pvesh get /cluster/nextid)
pveam update >/dev/null 2>&1
TEMPLATE_PATH=$(pveam available -section system | grep debian-12-standard | awk '{print $2}' | head -n 1)
if ! pveam list local | grep -q debian-12; then
    pveam download local "$TEMPLATE_PATH" >/dev/null 2>&1
fi
LOCAL_TEMPLATE=$(pveam list local | grep debian-12 | awk '{print $1}' | head -n 1)

echo -e "\n${YELLOW}Network Configuration for Sync LXC:${NC}"
echo "  [1] DHCP (Automatic IP)"
echo "  [2] Static IP"
read -p "Choose [1 or 2, Default: 1]: " NET_CHOICE < /dev/tty

if [ "$NET_CHOICE" == "2" ]; then
    GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
    CIDR=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1 | cut -d/ -f2)
    if [ -z "$CIDR" ]; then CIDR="24"; fi
    EXAMPLE_IP=$(echo "$GW" | awk -F. '{print $1"."$2"."$3".60"}')
    read -p "Enter the desired IP address (e.g. $EXAMPLE_IP): " STATIC_IP < /dev/tty
    if [ -z "$STATIC_IP" ]; then
        NET_CONFIG="name=eth0,bridge=vmbr0,ip=dhcp"
    else
        NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
    fi
else
    NET_CONFIG="name=eth0,bridge=vmbr0,ip=dhcp"
fi

TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi
LXC_NAME="SyncServer"

echo -e "${GREEN}[3/4] Creating LXC Container $CTID...${NC}"
pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --hostname "$LXC_NAME" --net0 $NET_CONFIG --unprivileged 1 --features nesting=1

if [ "$USE_EXTRA_DISK" == "yes" ]; then
    echo "Binding $MOUNT_DIR to LXC..."
    pct set $CTID -mp0 "$MOUNT_DIR,mp=/mnt/sync_data"
    # Ensure syncthing inside LXC (UID 1000 -> Host 101000) has access
    if [ "$FS_TYPE" == "ext4" ]; then
        chown -R 101000:101000 "$MOUNT_DIR"
    fi
fi

pct set $CTID -onboot 1
pct start $CTID
sleep 10

echo -e "${GREEN}[4/4] Installing Services (CouchDB & Syncthing)...${NC}"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl apt-transport-https gnupg ca-certificates sudo"

# COUCHDB
echo "Installing CouchDB..."
pct exec $CTID -- bash -c "killall -9 apt apt-get dpkg unattended-upgrades 2>/dev/null || true"
pct exec $CTID -- bash -c "rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock"
pct exec $CTID -- bash -c "dpkg --configure -a"

pct exec $CTID -- bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y adduser"
pct exec $CTID -- bash -c "useradd -r -d /opt/couchdb -M -s /usr/sbin/nologin couchdb 2>/dev/null || true"

pct exec $CTID -- bash -c "curl -fsSL https://couchdb.apache.org/repo/keys.asc | gpg --dearmor | tee /usr/share/keyrings/couchdb-archive-keyring.gpg >/dev/null 2>&1"
pct exec $CTID -- bash -c "source /etc/os-release && echo \"deb [signed-by=/usr/share/keyrings/couchdb-archive-keyring.gpg] https://apache.jfrog.io/artifactory/couchdb-deb/ \${VERSION_CODENAME} main\" | tee /etc/apt/sources.list.d/couchdb.list >/dev/null"
pct exec $CTID -- bash -c "echo 'couchdb couchdb/mode select standalone' | debconf-set-selections"
pct exec $CTID -- bash -c "echo 'couchdb couchdb/bindaddress string 0.0.0.0' | debconf-set-selections"
pct exec $CTID -- bash -c "echo 'couchdb couchdb/adminpass string $SYNC_PASS' | debconf-set-selections"
pct exec $CTID -- bash -c "echo 'couchdb couchdb/adminpass_again string $SYNC_PASS' | debconf-set-selections"
pct exec $CTID -- bash -c "echo 'couchdb couchdb/erlang_magic_cookie string couchdb' | debconf-set-selections"
pct exec $CTID -- bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y couchdb"

pct exec $CTID -- bash -c "cat <<EOF >> /opt/couchdb/etc/local.ini

[chttpd]
bind_address = 0.0.0.0

[admins]
admin = $SYNC_PASS
EOF"
pct exec $CTID -- bash -c "mkdir -p /opt/couchdb /etc/couchdb /var/lib/couchdb /var/log/couchdb /var/run/couchdb 2>/dev/null || true"
pct exec $CTID -- bash -c "chown -R couchdb:couchdb /opt/couchdb /etc/couchdb /var/lib/couchdb /var/log/couchdb /var/run/couchdb 2>/dev/null || true"
pct exec $CTID -- bash -c "systemctl restart couchdb"

echo "Waiting for CouchDB to start before configuring CORS..."
sleep 5

echo "Creating Custom Admin & Configuring CouchDB for Obsidian LiveSync..."
pct exec $CTID -- bash -c "curl -s -X PUT http://admin:${SYNC_PASS}@127.0.0.1:5984/_node/_local/_config/admins/${SYNC_USER} -d '\"${SYNC_PASS}\"'"
pct exec $CTID -- bash -c "curl -s -X PUT http://${SYNC_USER}:${SYNC_PASS}@127.0.0.1:5984/_node/_local/_config/httpd/enable_cors -d '\"true\"'"
pct exec $CTID -- bash -c "curl -s -X PUT http://${SYNC_USER}:${SYNC_PASS}@127.0.0.1:5984/_node/_local/_config/cors/origins -d '\"*\"'"
pct exec $CTID -- bash -c "curl -s -X PUT http://${SYNC_USER}:${SYNC_PASS}@127.0.0.1:5984/_node/_local/_config/cors/credentials -d '\"true\"'"
pct exec $CTID -- bash -c "curl -s -X PUT http://${SYNC_USER}:${SYNC_PASS}@127.0.0.1:5984/_node/_local/_config/cors/methods -d '\"GET, PUT, POST, HEAD, DELETE\"'"
pct exec $CTID -- bash -c "curl -s -X PUT http://${SYNC_USER}:${SYNC_PASS}@127.0.0.1:5984/_node/_local/_config/cors/headers -d '\"accept, authorization, content-type, origin, referer, x-csrf-token\"'"
pct exec $CTID -- bash -c "curl -s -X PUT http://${SYNC_USER}:${SYNC_PASS}@127.0.0.1:5984/_node/_local/_config/couchdb/max_document_size -d '\"50000000\"'"

# SYNCTHING
echo "Installing Syncthing..."
pct exec $CTID -- bash -c "curl -fsSL https://syncthing.net/release-key.gpg | gpg --dearmor -o /usr/share/keyrings/syncthing-archive-keyring.gpg"
pct exec $CTID -- bash -c "echo 'deb [signed-by=/usr/share/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable' | tee /etc/apt/sources.list.d/syncthing.list"
pct exec $CTID -- bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y syncthing"

echo "Configuring Syncthing..."
pct exec $CTID -- bash -c "useradd -m -s /bin/bash syncthing"
pct exec $CTID -- bash -c "sudo -u syncthing syncthing --generate=\"/home/syncthing/.config/syncthing\""
pct exec $CTID -- bash -c "sed -i 's/127.0.0.1:8384/0.0.0.0:8384/g' /home/syncthing/.config/syncthing/config.xml"
pct exec $CTID -- bash -c "sed -i 's/<globalAnnounceEnabled>true/<globalAnnounceEnabled>false/g' /home/syncthing/.config/syncthing/config.xml"
pct exec $CTID -- bash -c "sed -i 's/<relaysEnabled>true/<relaysEnabled>false/g' /home/syncthing/.config/syncthing/config.xml"
pct exec $CTID -- bash -c "sed -i 's/<natEnabled>true/<natEnabled>false/g' /home/syncthing/.config/syncthing/config.xml"

if [ "$USE_EXTRA_DISK" == "yes" ]; then
    pct exec $CTID -- bash -c "mkdir -p /mnt/sync_data"
    pct exec $CTID -- bash -c "chown syncthing:syncthing /mnt/sync_data"
fi

pct exec $CTID -- bash -c "systemctl enable syncthing@syncthing.service && systemctl start syncthing@syncthing.service"

LXC_IP=$(pct exec $CTID -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -n 1)

echo -e "${BLUE}=========================================="
echo -e " 🎉 SYNC SERVER IS READY!"
echo -e "==========================================${NC}"
echo -e "LXC Container ID : $CTID"
echo -e "IP Address       : ${YELLOW}$LXC_IP${NC}"
if [ "$USE_EXTRA_DISK" == "yes" ]; then
    echo -e "Storage Bound to : ${YELLOW}/mnt/sync_data${NC} (inside Syncthing)"
fi
echo -e ""
echo -e "${GREEN}1) Syncthing (Backups & File Sync)${NC}"
echo -e "URL: ${YELLOW}http://$LXC_IP:8384${NC}"
if [ "$USE_EXTRA_DISK" == "yes" ]; then
    echo -e "   -> When adding a folder in Syncthing, set its path to: /mnt/sync_data/YourFolderName"
fi
echo -e ""
echo -e "${GREEN}2) CouchDB (Obsidian LiveSync)${NC}"
echo -e "URL: ${YELLOW}http://$LXC_IP:5984/_utils/${NC}"
echo -e "Username: $SYNC_USER"
echo -e "Password: $SYNC_PASS"
echo -e ""
echo -e "${YELLOW}To configure Obsidian:${NC}"
echo -e " 1. Install 'Self-hosted LiveSync' plugin."
echo -e " 2. In plugin settings, enter URI: http://$LXC_IP:5984"
echo -e " 3. Username: $SYNC_USER / Password: $SYNC_PASS"
echo -e " 4. Database Name: obsidian"
echo -e " 5. Click 'Test' and then 'Check Database'. It will create the DB automatically."
echo -e "${BLUE}==========================================${NC}"

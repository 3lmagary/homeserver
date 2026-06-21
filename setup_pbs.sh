#!/bin/bash
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)
set -Eeuo pipefail

# ==========================================
# Proxmox Backup Server (Native LXC)
# ==========================================

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo -e "  Proxmox Backup Server Setup"
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

LXC_NAME="PBS-Server"
EXISTING_CTID=$(pct list 2>/dev/null | awk -v name="$LXC_NAME" '$3 == name {print $1}' || true)
if [ -n "$EXISTING_CTID" ]; then
    echo -e "${RED}Error: LXC '$LXC_NAME' already exists (ID: $EXISTING_CTID). Delete it first to reinstall.${NC}"
    exit 1
fi

# 1) DISPLAY ENVIRONMENT AND LIMITATIONS WARNING
echo -e "\n${RED}⚠️  PROXMOX BACKUP SERVER LXC LIMITATIONS WARNING ⚠️${NC}"
echo -e "Running Proxmox Backup Server (PBS) in an unprivileged container is highly efficient"
echo -e "but comes with the following key environment limitations:"
echo -e ""
echo -e " 1. ${YELLOW}Datastore Network Mounts (SMB/NFS):${NC}"
echo -e "    - Unprivileged containers cannot natively mount NFS or CIFS/SMB shares directly."
echo -e "    - ${GREEN}Recommendation:${NC} Mount the share on the Proxmox Host first, then use a Bind Mount"
echo -e "      (e.g., 'pct set <CTID> -mp0 /mnt/host-share,mp=/mnt/pbs-share') to map it to the container."
echo -e ""
echo -e " 2. ${YELLOW}I/O Disk Performance & Verification Integrity:${NC}"
echo -e "    - PBS runs heavy deduplication. Verification and Garbage Collection jobs are extremely"
echo -e "      I/O-intensive."
echo -e "    - ${GREEN}Recommendation:${NC} Use SSDs or NVMes for the datastore. Running PBS over slow USB disks"
echo -e "      or network shares will cause very slow verification jobs and potential backup timeouts."
echo -e ""
echo -e " 3. ${YELLOW}Single-File Restores (FUSE):${NC}"
echo -e "    - Restoring individual files from VM backups requires loop/FUSE device mounting."
echo -e "    - We will enable '--features fuse=1' during container creation to support this."
echo -e ""
read -p "Do you understand and accept these limitations? (y/N): " CONFIRM < /dev/tty
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Installation cancelled by user.${NC}"
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

# 2) NETWORK CONFIG
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

read -p "Enter Disk Size in GB (default: 30): " DISK_SIZE < /dev/tty
if [ -z "$DISK_SIZE" ]; then DISK_SIZE="30"; fi

NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

# Get Next ID
CTID=$(pvesh get /cluster/nextid)

echo -e "${GREEN}[1/4] Preparing LXC Container...${NC}"
pveam update >/dev/null 2>&1 || true
TEMPLATE_PATH=$(pveam available -section system | grep debian-12-standard | awk '{print $2}' | head -n 1)
if [ -z "$TEMPLATE_PATH" ]; then echo -e "${RED}Could not find Debian 12 template.${NC}"; exit 1; fi
if ! pveam list local | grep -q debian-12; then pveam download local "$TEMPLATE_PATH" >/dev/null 2>&1; fi
LOCAL_TEMPLATE=$(pveam list local | grep debian-12 | awk '{print $1}' | head -n 1)

echo "Creating PBS LXC $CTID on $TARGET_STORAGE..."
# We enable FUSE feature to support loop mounting inside the container (required for single-file restores)
pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --rootfs "$TARGET_STORAGE:$DISK_SIZE" --hostname "$LXC_NAME" \
    --net0 "$NET_CONFIG" --unprivileged 1 --features nesting=1,fuse=1
pct set $CTID -onboot 1 --timezone host
pct start $CTID

echo "Waiting for network..."
sleep 15

echo -e "${GREEN}[2/4] Configuring Proxmox Backup Server Repository...${NC}"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y wget gnupg ca-certificates"
pct exec $CTID -- bash -c "wget -qO /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg http://download.proxmox.com/debian/key.asc"
pct exec $CTID -- bash -c "echo 'deb http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription' > /etc/apt/sources.list.d/pbs.list"
pct exec $CTID -- bash -c "apt-get update"

echo -e "${GREEN}[3/4] Installing Proxmox Backup Server (native)...${NC}"
pct exec $CTID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-backup-server"

# Deployment successful - disable rollback
ROLLBACK_REQUIRED=false
trap - EXIT ERR

echo -e "\n${BLUE}=========================================="
echo -e " ✅ Proxmox Backup Server Installed!"
echo -e "==========================================${NC}"
echo -e "PBS Web Interface:  ${YELLOW}https://${STATIC_IP}:8007${NC}"
echo -e "Default User     :  ${GREEN}root${NC}"
echo -e "Password         :  (Use your container root password, or change it via Proxmox console)"
echo -e ""
echo -e "${YELLOW}Container Limitations and Best Practices reminder:${NC}"
echo -e " 1. Mount datastores on your host first, then map them using pct set -mp0."
echo -e " 2. Avoid using slow HDDs/USB drives; SSD storage is strongly recommended."
echo -e " 3. FUSE features are pre-configured to allow single-file restores."
echo -e ""
echo -e "\033[1;33mNote:\033[0m LXC root password prompt has been removed for better automation."
echo -e "To access this container's shell, run: \033[0;32mpct enter $CTID\033[0m from your Proxmox host."

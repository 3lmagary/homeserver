#!/bin/bash
echo -e "\033[0;34m[i] Configuring system-specific optimizations for your hardware...\033[0m"
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)

# ==========================================
# Proxmox Expandable NAS Setup Script
# ==========================================

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo " Proxmox Expandable NAS Setup (Samba)"
echo -e "==========================================${NC}"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root.${NC}"
  exit 1
fi

# Detect the current non-root sudo user, or fall back to searching /etc/passwd
SMB_USER="${SUDO_USER:-}"
if [ -z "$SMB_USER" ] || [ "$SMB_USER" == "root" ]; then
    SMB_USER=$(awk -F: '$3>=1000 && $3<65534 && $7~/bash|zsh|sh/ {print $1; exit}' /etc/passwd)
fi
if [ -z "$SMB_USER" ]; then SMB_USER="admin"; fi

# 1) DISK DETECTION & SELECTION
echo -e "${GREEN}[1/5] Scanning for available drives...${NC}"

# Find OS underlying disks (anything mounted at /, /boot, or part of LVM)
OS_BASES=$(lsblk -p -n -l -o NAME,FSTYPE,MOUNTPOINT | awk '$2=="LVM2_member" || $3=="/" || $3=="/boot" || $3=="/boot/efi" {print $1}' | sed -E 's/[0-9]+$//' | sort -u | paste -sd '|' -)

EXCLUDE_REGEX="^/dev/loop|^/dev/sr|^/dev/mapper|^/dev/pve|swap"
if [ -n "$OS_BASES" ]; then
    # This will exclude the entire physical OS disk and ALL its partitions (e.g. /dev/sda, /dev/sda1, etc)
    EXCLUDE_REGEX="$EXCLUDE_REGEX|^($OS_BASES)"
fi

# Get a reliable array of safe disks/partitions
SAFE_DEVS=$(lsblk -o NAME,TYPE -p -n -l | grep -vE "$EXCLUDE_REGEX")

mapfile -t DISK_PATHS < <(
    echo "$SAFE_DEVS" | while read -r name type; do
        if [ -z "$name" ]; then continue; fi
        if [ "$type" == "disk" ]; then
            # If the disk has children (e.g. sdb1), grep will find ^/dev/sdb[0-9]
            # So we only print the disk if grep does NOT find any children
            if ! echo "$SAFE_DEVS" | grep -qE "^${name}[0-9a-zA-Z]+"; then
                echo "$name"
            fi
        else
            # Always print partitions or other types (like md)
            echo "$name"
        fi
    done | sort
)

if [ ${#DISK_PATHS[@]} -eq 0 ]; then
    echo -e "${RED}No available disks found (other than the system drive). Connect a drive and try again.${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Available Disks/Partitions:${NC}"
i=1
for disk in "${DISK_PATHS[@]}"; do
    # Get details safely line by line to avoid column shifting
    D_SIZE=$(lsblk -o SIZE -n -d "$disk" 2>/dev/null | tr -d ' ')
    D_FSTYPE=$(blkid -s TYPE -o value "$disk" 2>/dev/null || echo "Unknown/None")
    D_MODEL=$(lsblk -o MODEL -n -d "$disk" 2>/dev/null | xargs)
    
    echo "[$i] $disk (Size: $D_SIZE, Format: $D_FSTYPE, Model: $D_MODEL)"
    ((i++))
done

echo ""
read -p "Enter the number of the drive/partition you want to use (e.g. 1): " DISK_NUM < /dev/tty

if ! [[ "$DISK_NUM" =~ ^[0-9]+$ ]] || [ "$DISK_NUM" -lt 1 ] || [ "$DISK_NUM" -gt "${#DISK_PATHS[@]}" ]; then
    echo -e "${RED}Invalid selection. Exiting.${NC}"
    exit 1
fi

SELECTED_DISK="${DISK_PATHS[$((DISK_NUM-1))]}"

echo -e "${GREEN}Selected Drive: $SELECTED_DISK${NC}"

# 2) FORMATTING LOGIC
FS_TYPE=$(blkid -s TYPE -o value "$SELECTED_DISK" || true)

if [ "$FS_TYPE" == "ext4" ] || [ "$FS_TYPE" == "xfs" ] || [ "$FS_TYPE" == "btrfs" ]; then
    echo -e "${GREEN}Drive is already formatted as native Linux ($FS_TYPE). No formatting needed.${NC}"
else
    if [ "$FS_TYPE" == "ntfs" ] || [ "$FS_TYPE" == "exfat" ]; then
        echo -e "${YELLOW}Warning: This drive is currently formatted as $FS_TYPE.${NC}"
    elif [ -z "$FS_TYPE" ]; then
        echo -e "${YELLOW}Warning: This drive has no known filesystem (unformatted).${NC}"
    fi

    echo -e "${YELLOW}For the best performance and stability on a server, Linux native format (ext4) is highly recommended.${NC}"
    read -p "Do you want to WIPE THIS ENTIRE DRIVE and format it to ext4? (y/N): " FORMAT_CHOICE < /dev/tty

    if [[ "$FORMAT_CHOICE" =~ ^[Yy]$ ]]; then
        echo -e "${RED}WARNING: ALL DATA ON $SELECTED_DISK WILL BE ERASED in 5 seconds...${NC}"
        sleep 5
        echo "Formatting to ext4..."
        mkfs.ext4 -F "$SELECTED_DISK"
        FS_TYPE="ext4"
        echo -e "${GREEN}Format complete!${NC}"
    else
        echo -e "${GREEN}Keeping existing format ($FS_TYPE).${NC}"
        if [ "$FS_TYPE" == "ntfs" ]; then
            echo "Installing ntfs-3g to support NTFS drives..."
            apt-get update >/dev/null 2>&1
            apt-get install -y ntfs-3g >/dev/null 2>&1
        fi
        if [ "$FS_TYPE" == "exfat" ]; then
            apt-get update >/dev/null 2>&1
            apt-get install -y exfat-fuse >/dev/null 2>&1
        fi
    fi
fi

# 3) PERSISTENT MOUNTING (HOST)
echo -e "${GREEN}[2/5] Mounting drive to Proxmox Host...${NC}"
UUID=$(blkid -s UUID -o value "$SELECTED_DISK")

if [ -z "$UUID" ]; then
    echo -e "${RED}Failed to extract UUID from $SELECTED_DISK. Cannot proceed.${NC}"
    exit 1
fi

# Check if already in fstab
EXISTING_MOUNT=$(grep "UUID=$UUID" /etc/fstab | awk '{print $2}')

if [ -n "$EXISTING_MOUNT" ]; then
    MOUNT_DIR="$EXISTING_MOUNT"
    echo -e "${YELLOW}Drive already exists in /etc/fstab at $MOUNT_DIR.${NC}"
else
    echo -e "\n${YELLOW}What do you want to name this Drive? (This will be its folder name on the server)${NC}"
    echo -e "Examples: Movies, Backup, Disk1"
    read -p "Drive Name [Default: Disk_$((RANDOM % 1000))]: " DRIVE_NAME < /dev/tty
    
    if [ -z "$DRIVE_NAME" ]; then
        DRIVE_NAME="Disk_$((RANDOM % 1000))"
    else
        DRIVE_NAME=$(echo "$DRIVE_NAME" | tr ' ' '_')
    fi
    
    MOUNT_DIR="/mnt/$DRIVE_NAME"
    mkdir -p "$MOUNT_DIR"
    
    echo "Adding drive to /etc/fstab for persistent mounting..."
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
if ! mountpoint -q "$MOUNT_DIR"; then
    echo -e "${RED}Failed to mount $SELECTED_DISK to $MOUNT_DIR.${NC}"
    exit 1
fi
echo -e "${GREEN}Successfully mounted at $MOUNT_DIR${NC}"

# 4) LXC DETECTION & CREATION
echo -e "${GREEN}[3/5] Setting up Samba NAS LXC...${NC}"

LXC_NAME="Samba-NAS"
EXISTING_CTID=$(pct list | awk -v name="$LXC_NAME" '$3 == name {print $1}')

if [ -n "$EXISTING_CTID" ]; then
    CTID="$EXISTING_CTID"
    echo -e "${YELLOW}Found existing NAS LXC (ID: $CTID). We will add this drive to it (Expandable NAS)!${NC}"
else
    echo -e "${GREEN}No existing NAS found. Creating a new LXC container...${NC}"
    
    # Get Next ID
    CTID=$(pvesh get /cluster/nextid)
    
    # Update templates if needed and download debian 12
    echo "Downloading Debian 12 Template..."
    pveam update >/dev/null 2>&1
    TEMPLATE_PATH=$(pveam available -section system | grep debian-12-standard | awk '{print $2}' | head -n 1)
    
    if [ -z "$TEMPLATE_PATH" ]; then
        echo -e "${RED}Could not find Debian 12 template.${NC}"
        exit 1
    fi
    
    # Download if not exists locally
    if ! pveam list local | grep -q debian-12; then
        pveam download local "$TEMPLATE_PATH" >/dev/null 2>&1
    fi
    
    LOCAL_TEMPLATE=$(pveam list local | grep debian-12 | awk '{print $1}' | head -n 1)
    
    GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
    CIDR=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1 | cut -d/ -f2)
    if [ -z "$CIDR" ]; then CIDR="24"; fi
    
    EXAMPLE_IP=$(echo "$GW" | awk -F. '{print $1"."$2"."$3".50"}')
    
    echo -e "\n${YELLOW}Network Configuration for NAS (Static IP Required):${NC}"
    echo -e "Detected Router/Gateway: $GW"
    read -p "Enter the desired IP address for the NAS (e.g. $EXAMPLE_IP): " STATIC_IP < /dev/tty
    if [ -z "$STATIC_IP" ]; then
        echo -e "${RED}Static IP is required for the NAS to work properly. Exiting.${NC}"
        exit 1
    fi
    NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"

    echo -e "\n${YELLOW}Do you want to protect your files with a password?${NC}"
    echo "  [Y] Yes - Secure, requires a username and password to access files (Recommended)."
    echo "  [N] No  - Public, ANYONE on your Wi-Fi network can read/delete your files."
    read -p "Choice (Y/n): " PASS_CHOICE < /dev/tty

    if [[ "$PASS_CHOICE" =~ ^[Nn]$ ]]; then
        SAMBA_MODE="guest"
        echo -e "${YELLOW}Samba will be configured for Public/Guest access.${NC}"
    else
        SAMBA_MODE="secure"
        read -sp "Enter a password for the Samba Share User ($SMB_USER): " SAMBA_PASS < /dev/tty
        echo
    fi
    
    TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
    if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi
    
    echo "Creating LXC Container $CTID on storage $TARGET_STORAGE..."
    pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --hostname "$LXC_NAME" --net0 $NET_CONFIG --unprivileged 1 --features nesting=1
    
    echo "Configuring NAS to start automatically on boot..."
    pct set $CTID -onboot 1
    
    echo "Starting LXC $CTID..."
    pct start $CTID
    
    echo "Waiting for network..."
    sleep 15
    
    echo "Installing Samba inside LXC..."
    pct exec $CTID -- bash -c "apt-get update && apt-get install -y samba"
    
    if [ "$SAMBA_MODE" == "secure" ]; then
        echo "Configuring secure Samba User..."
        pct exec $CTID -- bash -c "useradd -m -s /bin/bash $SMB_USER"
        pct exec $CTID -- bash -c "echo -e \"$SAMBA_PASS\n$SAMBA_PASS\" | smbpasswd -a -s $SMB_USER"
    else
        echo "Configuring public Samba Access..."
        pct exec $CTID -- bash -c "sed -i '/\[global\]/a \ \ \ \ map to guest = bad user' /etc/samba/smb.conf"
    fi
    
    # Store mode for future expansions
    pct exec $CTID -- bash -c "echo \"$SAMBA_MODE\" > /etc/samba_mode.txt"
fi

# 5) BIND MOUNT & SAMBA CONFIG
echo -e "${GREEN}[4/5] Binding drive to LXC and configuring share...${NC}"

# Get the mode from LXC (in case it was created previously)
SAMBA_MODE=$(pct exec $CTID -- cat /etc/samba_mode.txt 2>/dev/null || echo "secure")

# Find next available mp index
MAX_MP=-1
for MP in $(pct config $CTID | grep -o '^mp[0-9]*' | sed 's/mp//'); do
    if [ "$MP" -gt "$MAX_MP" ]; then
        MAX_MP=$MP
    fi
done
NEXT_MP=$((MAX_MP + 1))

DEFAULT_SHARE_NAME=$(basename "$MOUNT_DIR")

# Check if this directory is already mounted
if pct config $CTID | grep -q "$MOUNT_DIR,mp="; then
    echo -e "${YELLOW}Drive ($MOUNT_DIR) is already bound to LXC container $CTID. Skipping bind mount and Samba config.${NC}"
else
    echo -e "\n${YELLOW}What do you want to name this shared folder on the network?${NC}"
    echo -e "Examples: Movies, Backup, Files, $DEFAULT_SHARE_NAME"
    read -p "Share Name [Default: $DEFAULT_SHARE_NAME]: " USER_SHARE_NAME < /dev/tty

    if [ -z "$USER_SHARE_NAME" ]; then
        SHARE_NAME="$DEFAULT_SHARE_NAME"
    else
        # Replace spaces with underscores to avoid Samba share path issues
        SHARE_NAME=$(echo "$USER_SHARE_NAME" | tr ' ' '_')
    fi

    LXC_MOUNT_POINT="/share/$SHARE_NAME"

    echo "Adding Bind Mount (mp$NEXT_MP: $MOUNT_DIR -> $LXC_MOUNT_POINT)..."
    pct set $CTID -mp$NEXT_MP "$MOUNT_DIR,mp=$LXC_MOUNT_POINT"

    echo "Applying permissions (this may take several minutes for large drives)..."
    if [ "$FS_TYPE" == "ext4" ]; then
        # In unprivileged LXC, UID 1000 inside is 101000 on the host
        chown -R 101000:101000 "$MOUNT_DIR"
    fi

    echo "Updating Samba Config inside LXC..."
    if [ "$SAMBA_MODE" == "secure" ]; then
    SMB_CONF="
    [$SHARE_NAME]
       path = $LXC_MOUNT_POINT
       browseable = yes
       read only = no
       valid users = $SMB_USER
    "
    else
    SMB_CONF="
    [$SHARE_NAME]
       path = $LXC_MOUNT_POINT
       browseable = yes
       read only = no
       guest ok = yes
       public = yes
       force user = nobody
    "
    fi

    pct exec $CTID -- bash -c "echo '$SMB_CONF' >> /etc/samba/smb.conf"
    pct exec $CTID -- systemctl restart smbd
fi

# 6) FINISH
echo -e "${GREEN}[5/5] Setup Complete!${NC}"
LXC_IP=$(pct exec $CTID -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -n 1)

echo -e "${BLUE}=========================================="
echo -e " 🎉 NAS IS READY!"
echo -e "==========================================${NC}"
echo -e "The drive has been successfully added to your Samba NAS."
echo -e "LXC Container ID : $CTID"
echo -e "NAS IP Address   : ${YELLOW}$LXC_IP${NC}"
if [ "$SAMBA_MODE" == "secure" ]; then
    echo -e "Username         : $SMB_USER"
else
    echo -e "Mode             : Public (No Password)"
fi
echo -e ""
echo -e "To access your files:"
printf "• Windows: Open File Explorer and type %b\\\\\\\\%s%b\n" "${YELLOW}" "$LXC_IP" "${NC}"
echo -e "• Mac/Linux: Open your File Manager and type ${YELLOW}smb://$LXC_IP${NC}"
if [ "$SAMBA_MODE" == "secure" ]; then
    echo -e "\nLogin with Username: ${YELLOW}$SMB_USER${NC} and your password."
fi
echo -e "${BLUE}==========================================${NC}"

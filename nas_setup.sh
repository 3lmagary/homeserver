#!/bin/bash

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

# 1) DISK DETECTION & SELECTION
echo -e "${GREEN}[1/5] Scanning for available drives...${NC}"

# List block devices excluding loop, rom, and the main pve LVM partitions
AVAILABLE_DISKS=$(lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL -p -n -l | grep -vE "^/dev/pve|^/dev/mapper|swap|LVM2_member")

if [ -z "$AVAILABLE_DISKS" ]; then
    echo -e "${RED}No available disks found (other than the system drive). Connect a drive and try again.${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Available Disks/Partitions:${NC}"
echo "$AVAILABLE_DISKS" | awk '{printf "[%d] %s (Size: %s, Format: %s, Model: %s, Mount: %s)\n", NR, $1, $2, $3, $5, $4}'

echo ""
read -p "Enter the number of the drive/partition you want to use (e.g. 1): " DISK_NUM

SELECTED_DISK=$(echo "$AVAILABLE_DISKS" | sed -n "${DISK_NUM}p" | awk '{print $1}')

if [ -z "$SELECTED_DISK" ] || [ ! -b "$SELECTED_DISK" ]; then
    echo -e "${RED}Invalid selection or drive does not exist. Exiting.${NC}"
    exit 1
fi

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
    read -p "Do you want to WIPE THIS ENTIRE DRIVE and format it to ext4? (y/N): " FORMAT_CHOICE

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

MOUNT_DIR="/mnt/nas_disk_$UUID"
mkdir -p "$MOUNT_DIR"

# Check if already in fstab
if grep -q "$UUID" /etc/fstab; then
    echo -e "${YELLOW}Drive already exists in /etc/fstab.${NC}"
else
    echo "Adding drive to /etc/fstab for persistent mounting..."
    if [ "$FS_TYPE" == "ntfs" ]; then
        echo "UUID=$UUID $MOUNT_DIR ntfs-3g defaults,uid=1000,gid=1000,dmask=022,fmask=133 0 0" >> /etc/fstab
    elif [ "$FS_TYPE" == "ext4" ]; then
        echo "UUID=$UUID $MOUNT_DIR ext4 defaults 0 2" >> /etc/fstab
    else
        echo "UUID=$UUID $MOUNT_DIR auto defaults 0 0" >> /etc/fstab
    fi
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
    
    echo -e "\n${YELLOW}Network Configuration for NAS:${NC}"
    echo "  [1] DHCP (Automatic IP from Router)"
    echo "  [2] Static IP (Recommended so the IP never changes)"
    read -p "Choose [1 or 2, Default: 1]: " NET_CHOICE
    
    if [ "$NET_CHOICE" == "2" ]; then
        GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
        CIDR=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1 | cut -d/ -f2)
        if [ -z "$CIDR" ]; then CIDR="24"; fi
        
        echo -e "\nDetected Router/Gateway: $GW"
        read -p "Enter the desired IP address for the NAS (e.g. 192.168.1.50): " STATIC_IP
        if [ -z "$STATIC_IP" ]; then
            NET_CONFIG="name=eth0,bridge=vmbr0,ip=dhcp"
            echo "No IP entered. Falling back to DHCP."
        else
            NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
        fi
    else
        NET_CONFIG="name=eth0,bridge=vmbr0,ip=dhcp"
    fi

    echo -e "\n${YELLOW}Do you want to protect your files with a password?${NC}"
    echo "  [Y] Yes - Secure, requires a username and password to access files (Recommended)."
    echo "  [N] No  - Public, ANYONE on your Wi-Fi network can read/delete your files."
    read -p "Choice (Y/n): " PASS_CHOICE

    if [[ "$PASS_CHOICE" =~ ^[Nn]$ ]]; then
        SAMBA_MODE="guest"
        echo -e "${YELLOW}Samba will be configured for Public/Guest access.${NC}"
    else
        SAMBA_MODE="secure"
        read -p "Enter a password for the Samba Share User (admin): " SAMBA_PASS
    fi
    
    echo "Creating LXC Container $CTID..."
    pct create $CTID "$LOCAL_TEMPLATE" --hostname "$LXC_NAME" --net0 $NET_CONFIG --unprivileged 1 --features nesting=1
    
    echo "Configuring NAS to start automatically on boot..."
    pct set $CTID -onboot 1
    
    echo "Starting LXC $CTID..."
    pct start $CTID
    
    echo "Waiting for network..."
    sleep 10
    
    echo "Installing Samba inside LXC..."
    pct exec $CTID -- bash -c "apt-get update && apt-get install -y samba"
    
    if [ "$SAMBA_MODE" == "secure" ]; then
        echo "Configuring secure Samba User..."
        pct exec $CTID -- bash -c "useradd -m -s /bin/bash admin"
        pct exec $CTID -- bash -c "echo -e \"$SAMBA_PASS\n$SAMBA_PASS\" | smbpasswd -a -s admin"
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

echo -e "\n${YELLOW}What do you want to name this shared folder on the network?${NC}"
echo -e "Examples: Movies, Backup, Files, Disk_$NEXT_MP"
read -p "Share Name [Default: Disk_$NEXT_MP]: " USER_SHARE_NAME

if [ -z "$USER_SHARE_NAME" ]; then
    SHARE_NAME="Disk_$NEXT_MP"
else
    # Replace spaces with underscores to avoid Samba share path issues
    SHARE_NAME=$(echo "$USER_SHARE_NAME" | tr ' ' '_')
fi

LXC_MOUNT_POINT="/share/$SHARE_NAME"

echo "Adding Bind Mount (mp$NEXT_MP: $MOUNT_DIR -> $LXC_MOUNT_POINT)..."
pct set $CTID -mp$NEXT_MP "$MOUNT_DIR,mp=$LXC_MOUNT_POINT"

echo "Applying permissions..."
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
   valid users = admin
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
    echo -e "Username         : admin"
else
    echo -e "Mode             : Public (No Password)"
fi
echo -e ""
echo -e "To access your files from Windows:"
echo -e "1. Open File Explorer"
echo -e "2. In the address bar, type: ${YELLOW}\\\\$LXC_IP${NC}"
if [ "$SAMBA_MODE" == "secure" ]; then
    echo -e "3. Enter 'admin' and your password."
fi
echo -e "${BLUE}==========================================${NC}"

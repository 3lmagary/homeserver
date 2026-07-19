#!/bin/bash
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)
set -Eeuo pipefail

# ==========================================
# Tailscale VPN Gateway (Standalone LXC)
# ==========================================

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo -e "  Tailscale VPN Gateway (Standalone LXC)"
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

LXC_NAME="Tailscale-Gateway"
TS_HOSTNAME="server"
EXISTING_CTID=$(pct list 2>/dev/null | awk -v name="$LXC_NAME" '$3 == name {print $1}' || true)

IS_UPDATE=false
ROLLBACK_REQUIRED=true
CTID=""
STATIC_IP=""
ROLE_CHOICE="1"

if [ -n "$EXISTING_CTID" ]; then
    CTID="$EXISTING_CTID"
    IS_UPDATE=true
    ROLLBACK_REQUIRED=false
    echo -e "${YELLOW}LXC container '$LXC_NAME' already exists (ID: $CTID).${NC}"
    echo -e "${GREEN}Updating configuration and applying any changes...${NC}"

    if ! pct status "$CTID" | grep -q "status: running"; then
        echo -e "${YELLOW}Starting container $CTID...${NC}"
        pct start "$CTID"
        sleep 5
    fi

    STATIC_IP=$(pct config $CTID 2>/dev/null | grep "^net0:" | sed -n 's/.*ip=\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/p' || true)
    if [ -z "$STATIC_IP" ]; then
        STATIC_IP=$(pct exec $CTID -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -n 1 || true)
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

GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
CIDR=$(ip -o -f inet addr show scope global | awk '{print $4}' | head -n 1 | cut -d/ -f2)
if [ -z "$CIDR" ]; then CIDR="24"; fi
SUBNET_CIDR="${GW%.*}.0/${CIDR}"

if [ "$IS_UPDATE" = false ]; then
    echo -e "${GREEN}[1/5] Preparing LXC Container...${NC}"
    pveam update >/dev/null 2>&1 || true
    TEMPLATE_PATH=$(pveam available -section system | grep debian-12-standard | awk '{print $2}' | head -n 1)
    if [ -z "$TEMPLATE_PATH" ]; then echo -e "${RED}Could not find Debian 12 template.${NC}"; exit 1; fi
    if ! pveam list local | grep -q debian-12; then pveam download local "$TEMPLATE_PATH" >/dev/null 2>&1; fi
    LOCAL_TEMPLATE=$(pveam list local | grep debian-12 | awk '{print $1}' | head -n 1)

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

    if [ -t 0 ]; then
        read -p "Enter Disk Size in GB (default: 4): " DISK_SIZE
    else
        DISK_SIZE="4"
    fi
    if [ -z "$DISK_SIZE" ]; then DISK_SIZE="4"; fi
    if ! [[ "$DISK_SIZE" =~ ^[0-9]+$ ]]; then echo -e "${RED}Disk size must be a number.${NC}"; exit 1; fi

    echo -e "\n${YELLOW}Tailscale Role Configuration:${NC}"
    echo "[1] Subnet Router (route your whole LAN through Tailscale) (Recommended)"
    echo "[2] Exit Node (route all your device traffic through this home connection)"
    echo "[3] Both (Subnet Router + Exit Node)"
    if [ -t 0 ]; then
        read -p "Choice [1-3] (default: 1): " ROLE_CHOICE
    else
        ROLE_CHOICE="1"
    fi
    ROLE_CHOICE=${ROLE_CHOICE:-"1"}

    NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"
    TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
    if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi

    CTID=$(pvesh get /cluster/nextid)

    echo "Creating Tailscale LXC $CTID on $TARGET_STORAGE with ${DISK_SIZE}GB disk..."
    pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --rootfs "$TARGET_STORAGE:$DISK_SIZE" --hostname "$LXC_NAME" \
        --net0 "$NET_CONFIG" --unprivileged 1 --features nesting=1,keyctl=1
    pct set $CTID -onboot 1 --timezone host

    # Add TUN device pass-through to container configuration
    LXC_CONF="/etc/pve/lxc/${CTID}.conf"
    if ! grep -q "lxc.cgroup2.devices.allow: c 10:200 rwm" "$LXC_CONF"; then
        echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$LXC_CONF"
    fi
    if ! grep -q "lxc.mount.entry: /dev/net/tun dev/net/tun" "$LXC_CONF"; then
        echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> "$LXC_CONF"
    fi

    pct start $CTID

    echo "Waiting for network..."
    sleep 10
else
    echo -e "${GREEN}[1/5] Container exists, verifying network & TUN device...${NC}"
    LXC_CONF="/etc/pve/lxc/${CTID}.conf"
    UPDATED_CONF=false
    if ! grep -q "lxc.cgroup2.devices.allow: c 10:200 rwm" "$LXC_CONF"; then
        echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$LXC_CONF"
        UPDATED_CONF=true
    fi
    if ! grep -q "lxc.mount.entry: /dev/net/tun dev/net/tun" "$LXC_CONF"; then
        echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> "$LXC_CONF"
        UPDATED_CONF=true
    fi
    if [ "$UPDATED_CONF" = true ]; then
        echo -e "${YELLOW}Restarting LXC to apply TUN device configuration...${NC}"
        pct reboot "$CTID"
        sleep 5
    fi
fi

echo -e "${GREEN}[2/5] Enabling IP Forwarding inside Container...${NC}"
pct exec $CTID -- sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
pct exec $CTID -- sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
pct exec $CTID -- bash -c "mkdir -p /etc/sysctl.d && echo -e 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1' > /etc/sysctl.d/99-tailscale.conf" >/dev/null 2>&1 || true

echo -e "${GREEN}[3/5] Installing Tailscale & Dependencies...${NC}"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl ca-certificates iptables" >/dev/null 2>&1
pct exec $CTID -- bash -c "curl -fsSL https://tailscale.com/install.sh | sh" >/dev/null 2>&1

echo -e "${GREEN}[4/5] Starting Tailscale daemon...${NC}"
pct exec $CTID -- systemctl enable --now tailscaled >/dev/null 2>&1 || true
sleep 3

TS_UP_ARGS="--hostname=${TS_HOSTNAME} --accept-routes"
if [ "$ROLE_CHOICE" = "1" ] || [ "$ROLE_CHOICE" = "3" ]; then
    TS_UP_ARGS="$TS_UP_ARGS --advertise-routes=${SUBNET_CIDR}"
fi
if [ "$ROLE_CHOICE" = "2" ] || [ "$ROLE_CHOICE" = "3" ]; then
    TS_UP_ARGS="$TS_UP_ARGS --advertise-exit-node"
fi

echo -e "${GREEN}[5/5] Authenticating Tailscale...${NC}"
echo -e "${YELLOW}You will now be prompted to authenticate with Tailscale.${NC}"
echo -e "${YELLOW}Open the shown URL in your browser and log in, then return here.${NC}"
echo ""

# Auth failure should NOT destroy the container (keep it for manual retry)
if pct exec $CTID -- tailscale up $TS_UP_ARGS; then
    echo -e "${GREEN}✓ Tailscale authenticated and connected as '${TS_HOSTNAME}'.${NC}"
else
    echo -e "${RED}⚠️  Tailscale authentication pending or interrupted.${NC}"
    echo -e "${YELLOW}The container is ready. Complete authentication manually with:${NC}"
    echo -e "  pct exec $CTID -- tailscale up $TS_UP_ARGS"
    echo -e "Then check status with:"
    echo -e "  pct exec $CTID -- tailscale status"
fi

# ==========================================
# Register with Homepage Dashboard
# ==========================================
CORE_CTID=$(pct list 2>/dev/null | awk '$3 == "Core-Services" {print $1}' || true)
if [ -n "$CORE_CTID" ] && pct status "$CORE_CTID" 2>/dev/null | grep -q "status: running"; then
    echo -e "${GREEN}Registering Tailscale in Homepage Dashboard...${NC}"
    pct exec $CORE_CTID -- bash -c '
        CONF="/opt/core/homepage/services.yaml"
        if [ -f "$CONF" ] && ! grep -q -i "Tailscale" "$CONF"; then
            cat << "ENTRY" >> "$CONF"

- VPN & Network:
  - Tailscale:
      icon: tailscale
      href: https://login.tailscale.com/admin/machines
      description: Mesh VPN Gateway
ENTRY
        fi
    ' 2>/dev/null || true
fi

# Deployment successful - disable rollback
ROLLBACK_REQUIRED=false
trap - EXIT ERR

echo -e "\n${BLUE}=========================================="
echo -e " ✅ Tailscale Gateway Ready!"
echo -e "==========================================${NC}"
echo -e "${GREEN}▶ Tailscale Gateway${NC}"
echo -e "   - LXC Name: ${YELLOW}${LXC_NAME}${NC} (ID: ${CTID})"
echo -e "   - TS Name:  ${YELLOW}${TS_HOSTNAME}${NC}"
echo -e "   - LXC IP:   ${YELLOW}${STATIC_IP}${NC}"
echo -e "   - Status:   ${YELLOW}pct exec $CTID -- tailscale status${NC}"
echo -e ""
if [ "$ROLE_CHOICE" = "1" ] || [ "$ROLE_CHOICE" = "3" ]; then
    echo -e "${GREEN}▶ Subnet Router:${NC} advertises ${YELLOW}${SUBNET_CIDR}${NC}"
    echo -e "   Enable it in the Tailscale admin panel under the machine's"
    echo -e "   'Routes' section (approve the subnet)."
    echo -e ""
fi
if [ "$ROLE_CHOICE" = "2" ] || [ "$ROLE_CHOICE" = "3" ]; then
    echo -e "${GREEN}▶ Exit Node:${NC} enable it in the Tailscale admin panel"
    echo -e "   under the machine's 'Exit Node' settings."
    echo -e ""
fi
echo -e "${YELLOW}Note:${NC} After authenticating, approve the advertised routes/exit node"
echo -e "in the Tailscale admin console (https://login.tailscale.com)."
echo -e ""
echo -e "\033[1;33mNote:\033[0m To access this container's shell, run: \033[0;32mpct enter $CTID\033[0m from your Proxmox host."
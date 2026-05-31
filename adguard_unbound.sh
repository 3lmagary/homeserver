#!/bin/bash
set -e

# ==========================================
# Proxmox AdGuard Home + Unbound DNS Setup
# ==========================================

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo " Proxmox AdGuard + Unbound DNS Setup"
echo -e "==========================================${NC}"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root.${NC}"
  exit 1
fi

LXC_NAME="AdGuard-DNS"
EXISTING_CTID=$(pct list | awk -v name="$LXC_NAME" '$3 == name {print $1}')

if [ -n "$EXISTING_CTID" ]; then
    echo -e "${RED}Error: Found existing LXC container named $LXC_NAME (ID: $EXISTING_CTID).${NC}"
    echo "If you want to reinstall, please delete the old container first."
    exit 1
fi

echo -e "${GREEN}[1/5] Preparing LXC Container...${NC}"

# Get Next ID
CTID=$(pvesh get /cluster/nextid)

# Update templates and download debian 12
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

echo -e "\n${YELLOW}Network Configuration for DNS Server:${NC}"
echo -e " ⚠️ A DNS Server MUST have a Static IP to work reliably!"

GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
CIDR=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1 | cut -d/ -f2)
if [ -z "$CIDR" ]; then CIDR="24"; fi

EXAMPLE_IP=$(echo "$GW" | awk -F. '{print $1"."$2"."$3".53"}')

echo -e "\nDetected Router/Gateway: $GW"
read -p "Enter the desired STATIC IP address for AdGuard (e.g. $EXAMPLE_IP): " STATIC_IP < /dev/tty

if [ -z "$STATIC_IP" ]; then
    echo -e "${RED}Static IP is required for a DNS server. Exiting.${NC}"
    exit 1
fi


echo "Creating LXC Container $CTID on storage $TARGET_STORAGE..."
pct create $CTID "$LOCAL_TEMPLATE" --storage "$TARGET_STORAGE" --hostname "$LXC_NAME" --net0 "$NET_CONFIG" --unprivileged 1 --features nesting=1

echo "Configuring AdGuard to start automatically on boot..."
pct set $CTID -onboot 1

echo "Starting LXC $CTID..."
pct start $CTID

echo "Waiting for network..."
sleep 15

echo -e "${GREEN}[2/5] Updating Container...${NC}"
pct exec $CTID -- bash -c "export LC_ALL=C && export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get full-upgrade -y"
pct exec $CTID -- bash -c "export LC_ALL=C && export DEBIAN_FRONTEND=noninteractive && apt-get install -y unbound dnsutils curl wget ca-certificates"

echo -e "${GREEN}[3/5] Installing & Configuring Unbound...${NC}"
pct exec $CTID -- bash -c "wget -qO /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache"
pct exec $CTID -- bash -c "chown unbound:unbound /var/lib/unbound/root.hints"

UNBOUND_CONF="
server:
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no
    root-hints: \"/var/lib/unbound/root.hints\"
    harden-glue: yes
    harden-dnssec-stripped: yes
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    prefetch: yes
    num-threads: 2
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
"
pct exec $CTID -- bash -c "echo '$UNBOUND_CONF' > /etc/unbound/unbound.conf.d/adguard.conf"
pct exec $CTID -- systemctl enable unbound
pct exec $CTID -- systemctl restart unbound

echo -e "${GREEN}[4/5] Fixing Port 53 Conflicts...${NC}"
pct exec $CTID -- bash -c "systemctl disable --now systemd-resolved 2>/dev/null || true"

echo -e "${GREEN}[5/5] Installing AdGuard Home...${NC}"
pct exec $CTID -- bash -c "curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh"

echo -e "${BLUE}=========================================="
echo -e " ✅ DNS SERVER IS READY!"
echo -e "==========================================${NC}"
echo -e "LXC Container ID : $CTID"
echo -e "AdGuard IP       : ${YELLOW}$STATIC_IP${NC}"
echo -e ""
echo -e "To complete the setup, open your browser and go to:"
echo -e "${YELLOW}http://$STATIC_IP:3000${NC}"
echo -e ""
echo -e " ⚠️ ${RED}IMPORTANT DURING SETUP:${NC} ⚠️"
echo -e "When asked for the 'Upstream DNS servers', delete everything and put EXACTLY this:"
echo -e "${YELLOW}127.0.0.1:5335${NC}"
echo -e ""
echo -e "For 'Bootstrap DNS servers', put:"
echo -e "${YELLOW}1.1.1.1${NC}"
echo -e ""
echo -e "${GREEN}▶ Proxmox LXC Server (SSH/Console) ${NC}"
echo -e "   - IP:       ${YELLOW}${STATIC_IP}${NC}"
echo -e "   - User:     ${YELLOW}root${NC}"
echo -e "${BLUE}==========================================${NC}"

echo -e ""
echo -e "\033[1;33mNote:\033[0m LXC root password prompt has been removed for better automation."
echo -e "To access this container's shell, run: \033[0;32mpct enter \$CTID\033[0m from your Proxmox host."

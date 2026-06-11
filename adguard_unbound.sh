#!/bin/bash
set -Eeuo pipefail

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
EXISTING_CTID=$(pct list 2>/dev/null | awk -v name="$LXC_NAME" '$3 == name {print $1}' || true)

if [ -n "$EXISTING_CTID" ]; then
    echo -e "${RED}Error: Found existing LXC container named $LXC_NAME (ID: $EXISTING_CTID).${NC}"
    echo "If you want to reinstall, please delete the old container first."
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

echo -e "${GREEN}[1/5] Preparing LXC Container...${NC}"

# Get Next ID
CTID=$(pvesh get /cluster/nextid)

# Update templates and download debian 12
echo "Downloading Debian 12 Template..."
pveam update >/dev/null 2>&1 || true
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

echo -ne "\nScanning network to find a free static IP automatically..."
find_free_ip() {
    local gw="$1"
    local base_ip=$(echo "$gw" | cut -d. -f1-3)
    local assigned_ips
    assigned_ips=$(grep -r -o -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' /etc/pve/lxc/ /etc/pve/qemu-server/ 2>/dev/null | cut -d: -f2 | sort -u || true)
    local tmp_dir=$(mktemp -d)
    for i in {53..150}; do
        local test_ip="${base_ip}.${i}"
        if [ "$test_ip" = "$gw" ] || echo "$assigned_ips" | grep -q -w "$test_ip"; then
            continue
        fi
        ( ping -c 1 -W 1 "$test_ip" &>/dev/null && touch "${tmp_dir}/${i}" ) &
    done
    sleep 1.2
    local free_ip=""
    for i in {53..150}; do
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

TARGET_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n 1)
if [ -z "$TARGET_STORAGE" ]; then TARGET_STORAGE="local-lvm"; fi
NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP}/${CIDR},gw=${GW}"

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

# Deployment successful - disable rollback
ROLLBACK_REQUIRED=false
trap - EXIT ERR

# --- Configure AdGuard Home for Port 80 and Unbound ---
echo -e "${GREEN}Configuring AdGuard Home to listen on port 80 and use Unbound...${NC}"
pct exec $CTID -- systemctl stop AdGuardHome &>/dev/null || true
sleep 2

# Try to use python venv of auto_exposer to edit YAML cleanly
if [ -d "/opt/homeserver/auto_exposer" ] && [ -f "/opt/homeserver/auto_exposer/venv/bin/python" ]; then
    TEMP_YAML=$(mktemp)
    pct pull $CTID /opt/AdGuardHome/AdGuardHome.yaml "$TEMP_YAML" 2>/dev/null || touch "$TEMP_YAML"
    /opt/homeserver/auto_exposer/venv/bin/python -c "
import yaml
config_path = '${TEMP_YAML}'
try:
    with open(config_path, 'r') as f:
        data = yaml.safe_load(f) or {}
except Exception:
    data = {}
if 'http' not in data or not isinstance(data['http'], dict):
    data['http'] = {}
data['http']['address'] = '0.0.0.0:80'
if 'dns' not in data or not isinstance(data['dns'], dict):
    data['dns'] = {}
data['dns']['upstream_dns'] = ['127.0.0.1:5335']
with open(config_path, 'w') as f:
    yaml.dump(data, f)
"
    pct push $CTID "$TEMP_YAML" /opt/AdGuardHome/AdGuardHome.yaml
    rm -f "$TEMP_YAML"
else
    # Fallback if PyYAML/auto_exposer is not present
    pct exec $CTID -- bash -c "
        if [ ! -f /opt/AdGuardHome/AdGuardHome.yaml ]; then
            cat <<EOF > /opt/AdGuardHome/AdGuardHome.yaml
http:
  address: 0.0.0.0:80
dns:
  upstream_dns:
  - 127.0.0.1:5335
EOF
        else
            sed -i 's/address: 0.0.0.0:3000/address: 0.0.0.0:80/g' /opt/AdGuardHome/AdGuardHome.yaml || true
            sed -i 's/bind_port: 3000/bind_port: 80/g' /opt/AdGuardHome/AdGuardHome.yaml || true
        fi
    "
fi

pct exec $CTID -- systemctl start AdGuardHome &>/dev/null || true

# --- AutoExposer Integration ---
CF_DOMAIN=""
if [ -f "/opt/homeserver/auto_exposer/.env" ]; then
    CF_DOMAIN=$(grep -E "^CF_DOMAIN=" /opt/homeserver/auto_exposer/.env | cut -d= -f2- | tr -d '"'\'' ')
fi

if [ -n "$CF_DOMAIN" ] && [ -d "/opt/homeserver/auto_exposer" ]; then
    echo -e "${GREEN}Triggering AutoExposer to automatically expose AdGuard via domain: adguard.${CF_DOMAIN}...${NC}"
    (
        cd /opt/homeserver/auto_exposer
        ./venv/bin/python main.py sync
    )
fi

echo -e "${BLUE}=========================================="
echo -e " ✅ DNS SERVER IS READY!"
echo -e "==========================================${NC}"
echo -e "LXC Container ID : $CTID"
echo -e "AdGuard IP       : ${YELLOW}$STATIC_IP${NC}"
echo -e ""

if [ -n "$CF_DOMAIN" ]; then
    echo -e "To complete the setup, open your browser and go to:"
    echo -e "${YELLOW}https://adguard.$CF_DOMAIN${NC} (or ${YELLOW}http://adguard.$CF_DOMAIN${NC})"
else
    echo -e "To complete the setup, open your browser and go to:"
    echo -e "${YELLOW}http://$STATIC_IP${NC}"
fi

echo -e ""
echo -e " ⚠️  ${RED}NOTE DURING SETUP:${NC}"
echo -e "The DNS upstream server has been pre-configured to: ${YELLOW}127.0.0.1:5335${NC} (Unbound)."
echo -e "The setup wizard is configured to run on port 80."
echo -e ""
echo -e "${GREEN}▶ Proxmox LXC Server (SSH/Console) ${NC}"
echo -e "   - IP:       ${YELLOW}${STATIC_IP}${NC}"
echo -e "   - User:     ${YELLOW}root${NC}"
echo -e "${BLUE}==========================================${NC}"

echo -e ""
echo -e "\033[1;33mNote:\033[0m LXC root password prompt has been removed for better automation."
echo -e "To access this container's shell, run: \033[0;32mpct enter $CTID\033[0m from your Proxmox host."

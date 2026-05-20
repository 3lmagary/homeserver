#!/bin/bash

set -e

# =========================================================
# Ultimate DNS Setup: AdGuard Home + Unbound (LXC)
# =========================================================

GREEN="\033[0;32m"
BLUE="\033[0;34m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BLUE}==============================================="
echo " AdGuard Home + Unbound Setup Script (LXC)"
echo -e "===============================================${NC}"

# 1. Update system
echo -e "${GREEN}[1/5] Updating system...${NC}"
apt update && apt full-upgrade -y

# 2. Free up Port 53 (Disable systemd-resolved if active)
echo -e "${GREEN}[2/5] Freeing up Port 53 (Fixing conflicts)...${NC}"
if systemctl is-active --quiet systemd-resolved; then
    systemctl disable --now systemd-resolved || true
    rm -f /etc/resolv.conf
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
fi

# 3. Install and Configure Unbound
echo -e "${GREEN}[3/5] Installing and Configuring Unbound...${NC}"
apt install -y unbound ca-certificates curl dnsutils

# Download root hints
wget -qO /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache
chown unbound:unbound /var/lib/unbound/root.hints

# Create Unbound config for AdGuard Home
cat << 'EOF' > /etc/unbound/unbound.conf.d/adguard.conf
server:
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no
    prefer-ip6: no
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    edns-buffer-size: 1232
    prefetch: yes
    num-threads: 1
    so-rcvbuf: 1m
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: fd00::/8
    private-address: fe80::/10
EOF

systemctl restart unbound
systemctl enable unbound

# 4. Install AdGuard Home
echo -e "${GREEN}[4/5] Installing AdGuard Home...${NC}"
curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v

# 5. Done
echo -e "${GREEN}[5/5] Cleaning up system...${NC}"
apt autoremove -y
apt clean

echo -e "${BLUE}===============================================${NC}"
echo -e "${GREEN}🎉 SETUP COMPLETE! 🎉${NC}"
echo -e "${BLUE}===============================================${NC}"

IP=$(hostname -I | awk '{print $1}')
echo -e "👉 1. Open your browser: ${GREEN}http://$IP:3000${NC}"
echo -e "👉 2. Complete the AdGuard Home setup wizard."
echo -e "👉 3. Inside AdGuard Home, go to ${YELLOW}Settings -> DNS Settings${NC}:"
echo -e "      Set Upstream DNS to:   ${GREEN}127.0.0.1:5335${NC}"
echo -e "      Set Bootstrap DNS to:  ${GREEN}1.1.1.1${NC}"
echo -e "👉 4. Click 'Apply' and 'Test upstreams'."
echo -e "${BLUE}===============================================${NC}"

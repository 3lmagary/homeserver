#!/bin/bash
set -e

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo -e "${BLUE}=========================================="
echo -e "  Starting AutoExposer Platform"
echo -e "==========================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}Warning: You should probably run this as root on Proxmox.${NC}"
fi

if ! command -v git &> /dev/null; then
    echo -e "${GREEN}Installing git...${NC}"
    apt-get update >/dev/null 2>&1
    apt-get install -y git >/dev/null 2>&1
fi

if [ -d "/opt/homeserver" ]; then
    echo -e "${GREEN}Updating AutoExposer repository...${NC}"
    cd /opt/homeserver
    git pull origin main -q
else
    echo -e "${GREEN}Downloading AutoExposer Platform...${NC}"
    cd /opt
    git clone https://github.com/3lmagary/homeserver.git -q
    cd homeserver
fi

cd auto_exposer

# Install Python venv if missing (Debian/Proxmox)
if ! dpkg -l | grep -q python3-venv; then
    echo -e "${GREEN}Installing python3-venv...${NC}"
    apt-get update >/dev/null 2>&1
    apt-get install -y python3-venv python3-pip >/dev/null 2>&1
fi

# Setup Virtual Environment
if [ ! -d "venv" ]; then
    echo -e "${GREEN}Creating Python virtual environment...${NC}"
    python3 -m venv venv
fi

# Activate and install requirements
source venv/bin/activate
echo -e "${GREEN}Verifying dependencies...${NC}"
pip install -r requirements.txt -q

# Ensure .env exists
if [ ! -f ".env" ]; then
    echo -e "${YELLOW}No .env file found. Setting it up now!${NC}"
    
    # Smart Auto-discover NPM IP by scanning all LXCs for the NPM Docker container
    echo -e "${BLUE}Scanning LXCs to find Nginx Proxy Manager...${NC}"
    AUTO_NPM_URL=""
    for CT in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
        if pct exec $CT -- bash -c "command -v docker >/dev/null && docker ps | grep -q 'nginx-proxy-manager'" 2>/dev/null; then
            CORE_IP=$(pct exec $CT -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -n 1)
            AUTO_NPM_URL="http://${CORE_IP}:81"
            echo -e "${GREEN}✓ Found NPM running on LXC $CT (IP: $CORE_IP)${NC}"
            break
        fi
    done
    
    if [ -z "$AUTO_NPM_URL" ]; then
        read -p "Could not auto-detect NPM. Enter NPM URL (e.g. http://192.168.1.50:81): " AUTO_NPM_URL < /dev/tty
    fi
    
    echo ""
    read -p "NPM Email [Default: admin@example.com]: " NPM_EMAIL < /dev/tty
    NPM_EMAIL=${NPM_EMAIL:-"admin@example.com"}
    
    read -sp "NPM Password [Default: changeme]: " NPM_PASSWORD < /dev/tty
    NPM_PASSWORD=${NPM_PASSWORD:-"changeme"}
    echo ""
    
    echo ""
    read -sp "Enter Cloudflare API Token: " CF_API_TOKEN < /dev/tty
    echo ""
    read -p "Enter Your Domain Name (e.g. example.com): " CF_DOMAIN < /dev/tty
    
    cat << EOF > .env
NPM_URL=$AUTO_NPM_URL
NPM_EMAIL=$NPM_EMAIL
NPM_PASSWORD=$NPM_PASSWORD
CF_API_TOKEN=$CF_API_TOKEN
CF_DOMAIN=$CF_DOMAIN
EOF
    echo -e "${GREEN}.env file created successfully!${NC}"
fi

echo -e "${GREEN}Launching AutoExposer...${NC}"
python main.py sync

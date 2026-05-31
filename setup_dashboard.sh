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

# Navigate to the auto_exposer directory
cd "$(dirname "$0")/auto_exposer"

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
    echo -e "${YELLOW}Warning: .env file not found. Creating from .env.example...${NC}"
    cp .env.example .env
    echo ""
    echo -e "${RED}ACTION REQUIRED:${NC}"
    echo -e "Please edit ${BOLD}auto_exposer/.env${NC} and put your Cloudflare and NPM credentials."
    echo -e "After editing, run this script again."
    exit 1
fi

echo -e "${GREEN}Launching AutoExposer...${NC}"
python main.py sync

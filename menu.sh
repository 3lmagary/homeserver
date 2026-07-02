#!/bin/bash
echo -e "\033[0;34m[i] Configuring system-specific optimizations for your hardware...\033[0m"
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)
set -Eeuo pipefail

# Silence locale warnings
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export LANGUAGE=C.UTF-8


# ==========================================
# Ultimate Home Server Setup - Unified Menu
# ==========================================

# Ensure script is run as root
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
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m"
ESC=$(printf '\033')

echo -e "${BLUE}=========================================="
echo -e "         Interactive Setup Menu"
echo -e "==========================================${NC}"

# Auto-update logic: Ensure user always has the latest scripts
echo -e "${GREEN}[i] Checking for repository updates...${NC}"
if ! command -v git &> /dev/null; then
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y git >/dev/null 2>&1 || true
fi

REPO_DIR="/opt/homeserver"
REMOTE_BRANCH="origin/main"

if [ -d "/opt/homeserver" ]; then
    cd /opt/homeserver
    git fetch origin main -q
    
    # Check if we are behind origin/main
    LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "")
    REMOTE=$(git rev-parse origin/main 2>/dev/null || echo "")
    BASE=$(git merge-base HEAD origin/main 2>/dev/null || echo "")
    
    if [ -n "$LOCAL" ] && [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ] && [ "$LOCAL" = "$BASE" ]; then
        echo -e "${GREEN}[i] Pulling the latest updates from GitHub...${NC}"
        git stash -q || true
        git pull origin main -q || true
        git stash pop -q || true
        echo -e "${GREEN}Repository updated successfully. Reloading menu...${NC}"
        sleep 1
        exec bash /opt/homeserver/menu.sh "$@"
    fi
else
    git clone https://github.com/3lmagary/homeserver.git /opt/homeserver -q
    cd /opt/homeserver
    git fetch origin main -q
fi

COSYNC_UPDATE_AVAILABLE=""
EXISTING_CTID=$(pct list 2>/dev/null | awk '$3 == "SyncServer" {print $1}' || true)
if [ -n "$EXISTING_CTID" ] && pct status "$EXISTING_CTID" 2>/dev/null | grep -q "status: running"; then
    echo -e "${GREEN}[i] Checking for CoSync updates inside LXC...${NC}"
    LOCAL_HASH=$(pct exec "$EXISTING_CTID" -- bash -c "cd /opt/cosync && git rev-parse HEAD" 2>/dev/null || true)
    REMOTE_HASH=$(git ls-remote git@github.com:3lmagary/CoSync.git refs/heads/main 2>/dev/null | awk '{print $1}' || true)
    if [ -z "$REMOTE_HASH" ]; then
        REMOTE_HASH=$(git ls-remote https://github.com/3lmagary/CoSync.git refs/heads/main 2>/dev/null | awk '{print $1}' || true)
    fi
    if [ -n "$LOCAL_HASH" ] && [ -n "$REMOTE_HASH" ] && [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
        COSYNC_UPDATE_AVAILABLE=" [Update Available]"
    fi
fi

SCRIPT_FILES=("setup.sh" "nas_setup.sh" "adguard_unbound.sh" "setup_core.sh" "setup_dashboard.sh" "setup_hermes.sh" "setup_n8n.sh" "sync_setup.sh")
declare -A SCRIPT_TITLES
SCRIPT_TITLES["setup.sh"]="Proxmox Base Node Setup"
SCRIPT_TITLES["nas_setup.sh"]="Expandable Samba NAS Setup"
SCRIPT_TITLES["setup_core.sh"]="Core Services Setup (NPM, Vaultwarden, Homepage, Portainer)"
SCRIPT_TITLES["setup_dashboard.sh"]="AutoExposer DNS/SSL/Homepage Sync (Python)"
SCRIPT_TITLES["adguard_unbound.sh"]="AdGuard Home + Unbound DNS Setup"
SCRIPT_TITLES["setup_hermes.sh"]="Hermes AI Agent Stack (Autonomous AI Agent & Dashboard)"
SCRIPT_TITLES["setup_n8n.sh"]="n8n + Evolution API + Postgres Setup (Automation Stack)"
SCRIPT_TITLES["sync_setup.sh"]="Sync & Backup Server (CoSync + Syncthing + Kopia)"

# Dynamically scan for available scripts
AVAILABLE_SCRIPTS=()
for key in "${SCRIPT_FILES[@]}"; do
    if [ -f "$key" ]; then
        AVAILABLE_SCRIPTS+=("$key")
    fi
done

if [ ${#AVAILABLE_SCRIPTS[@]} -eq 0 ]; then
    echo -e "${RED}Error: No setup scripts found in the current directory ($SCRIPT_DIR).${NC}"
    exit 1
fi

cursor_up() { printf "${ESC}[%dA" "${1:-1}"; }
clear_line() { printf "${ESC}[2K"; }
hide_cursor() { printf "${ESC}[?25l"; }
show_cursor() { printf "${ESC}[?25h"; }

# Make sure we restore cursor on exit/interrupt
cleanup() {
    show_cursor
    exit 0
}
trap cleanup INT TERM
trap show_cursor EXIT

# Build the options array
options=()
for script in "${AVAILABLE_SCRIPTS[@]}"; do
    title="${SCRIPT_TITLES[$script]:-$script}"
    if [ "$script" == "sync_setup.sh" ] && [ -n "$COSYNC_UPDATE_AVAILABLE" ]; then
        options+=("$title (${BLUE}$script${NC})${RED}${COSYNC_UPDATE_AVAILABLE}${NC}")
    else
        options+=("$title (${BLUE}$script${NC})")
    fi
done
options+=("${RED}Exit Menu${NC}")

selected=0
num_options=${#options[@]}

while true; do
    clear
    echo -e "${BLUE}=============================================================="
    echo -e "         🚀 Ultimate Home Server Setup - Interactive Menu"
    echo -e "==============================================================${NC}"
    echo -e "Use the ${BOLD}Up/Down Arrow Keys${NC} to navigate and press ${BOLD}Enter${NC} to select:\n"
    
    # Hide cursor
    hide_cursor
    
    # Draw initial list
    for i in "${!options[@]}"; do
        if [ "$i" -eq "$selected" ]; then
            echo -e "  ${BOLD}${YELLOW}➜  ${options[$i]}${NC}"
        else
            echo -e "     ${options[$i]}"
        fi
    done
    echo -e "\n${BLUE}==============================================================${NC}"
    
    # Flush any leftover keypresses in the input buffer first
    read -t 0.1 -N 1000000 < /dev/tty 2>/dev/null || true
    
    # Selection loop
    set +e
    while true; do
        # Read keypress (3 chars max for escape codes) from /dev/tty
        IFS= read -r -n 3 -s key < /dev/tty 2>/dev/null
        status=$?
        
        # If read failed (e.g. timeout, signal, or EOF), ignore and continue
        if [ $status -ne 0 ]; then
            sleep 0.05
            continue
        fi
        
        # Up Arrow
        if [[ "$key" == $'\x1b[A' ]]; then
            if [ "$selected" -gt 0 ]; then
                ((selected--))
                # Move up past the border (1) and empty line (1) and options list (num_options)
                cursor_up $((num_options + 2))
                for i in "${!options[@]}"; do
                    clear_line
                    if [ "$i" -eq "$selected" ]; then
                        echo -e "  ${BOLD}${YELLOW}➜  ${options[$i]}${NC}"
                    else
                        echo -e "     ${options[$i]}"
                    fi
                done
                clear_line
                echo -e "\n${BLUE}==============================================================${NC}"
            fi
        # Down Arrow
        elif [[ "$key" == $'\x1b[B' ]]; then
            if [ "$selected" -lt $((num_options - 1)) ]; then
                ((selected++))
                cursor_up $((num_options + 2))
                for i in "${!options[@]}"; do
                    clear_line
                    if [ "$i" -eq "$selected" ]; then
                        echo -e "  ${BOLD}${YELLOW}➜  ${options[$i]}${NC}"
                    else
                        echo -e "     ${options[$i]}"
                    fi
                done
                clear_line
                echo -e "\n${BLUE}==============================================================${NC}"
            fi
        # Enter (Only if read was successful and key is empty/newline)
        elif [[ "$key" == "" ]]; then
            break
        fi
    done
    set -e
    show_cursor
    
    # If "Exit Menu" is selected
    if [ "$selected" -eq $((num_options - 1)) ]; then
        echo -e "\n${GREEN}Goodbye!${NC}"
        exit 0
    fi
    
    # Execute selected script
    SELECTED_SCRIPT="${AVAILABLE_SCRIPTS[$selected]}"
    SELECTED_TITLE="${SCRIPT_TITLES[$SELECTED_SCRIPT]:-$SELECTED_SCRIPT}"

    # Update check is now handled automatically at startup
    
    echo -e "\n${GREEN}Starting: $SELECTED_TITLE...${NC}"
    echo -e "${YELLOW}--------------------------------------------------------------${NC}\n"
    
    # Run the script and preserve exit code
    set +e
    bash "./$SELECTED_SCRIPT"
    STATUS=$?
    set -e
    
    echo -e "\n${YELLOW}--------------------------------------------------------------${NC}"
    if [ $STATUS -eq 0 ]; then
        echo -e "${GREEN}✓ Execution completed successfully!${NC}"
    else
        echo -e "${RED}✗ Execution failed with status $STATUS.${NC}"
    fi
    echo -e "Press Enter to return to the menu..."
    read -r < /dev/tty
done

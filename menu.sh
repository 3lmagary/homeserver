#!/bin/bash
echo -e "\033[0;34m[i] Configuring system-specific optimizations for your hardware...\033[0m"
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)
set -Eeuo pipefail

# ==========================================
# Ultimate Home Server Setup - Unified Menu
# ==========================================

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[0;31mError: Please run this menu script as root or using sudo.\033[0m"
  exit 1
fi

# Auto-update logic: Ensure user always has the latest scripts
echo -e "\033[0;32m[i] Checking for repository updates...\033[0m"
if ! command -v git &> /dev/null; then
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y git >/dev/null 2>&1 || true
fi

if [ -d "/opt/homeserver" ]; then
    cd /opt/homeserver
    # Reset any local changes to ensure clean update
    git fetch origin main -q
    git reset --hard origin/main -q
else
    git clone https://github.com/3lmagary/homeserver.git /opt/homeserver -q
    cd /opt/homeserver
fi
declare -A SCRIPT_TITLES
SCRIPT_TITLES["setup.sh"]="Proxmox Base Node Setup"
SCRIPT_TITLES["nas_setup.sh"]="Expandable Samba NAS Setup"
SCRIPT_TITLES["setup_core.sh"]="Core Services Setup (NPM, Vaultwarden, Homepage, Portainer)"
SCRIPT_TITLES["setup_dashboard.sh"]="AutoExposer DNS/SSL/Homepage Sync (Python)"
SCRIPT_TITLES["adguard_unbound.sh"]="AdGuard Home + Unbound DNS Setup"
SCRIPT_TITLES["setup_hermes.sh"]="Hermes AI Agent Stack (Autonomous AI Agent & Dashboard)"

# Dynamically scan for available scripts
AVAILABLE_SCRIPTS=()
for key in "setup.sh" "nas_setup.sh" "adguard_unbound.sh" "setup_core.sh" "setup_dashboard.sh" "setup_hermes.sh"; do
    if [ -f "$key" ]; then
        AVAILABLE_SCRIPTS+=("$key")
    fi
done

if [ ${#AVAILABLE_SCRIPTS[@]} -eq 0 ]; then
    echo -e "${RED}Error: No setup scripts found in the current directory ($SCRIPT_DIR).${NC}"
    exit 1
fi

# ANSI Escape Codes and helpers for arrow key navigation
ESC=$(printf '\033')
BOLD="\033[1m"
CYAN="\033[0;36m"
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

cursor_up() { printf "${ESC}[%dA" "${1:-1}"; }
clear_line() { printf "${ESC}[2K"; }
hide_cursor() { printf "${ESC}[?25l"; }
show_cursor() { printf "${ESC}[?25h"; }

# Make sure we restore cursor on exit/interrupt
trap show_cursor EXIT INT TERM

# Build the options array
options=()
for script in "${AVAILABLE_SCRIPTS[@]}"; do
    title="${SCRIPT_TITLES[$script]:-$script}"
    options+=("$title (${BLUE}$script${NC})")
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

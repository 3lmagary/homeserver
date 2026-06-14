#!/bin/bash

# Configuration
SERVER_URL="https://pulse.3lmagary.com/collect"
API_KEY='$Pc5&^O@A*qumH1R8gGvY6DY#J#2YlI#idR%J^xF4Ru3P!8!1l' 
ID_FILE="$HOME/.homeserver_id"

if [ "$API_KEY" = "default-api-key" ]; then
    exit 0
fi

if ! command -v curl &> /dev/null; then
    exit 0
fi

exec 9>/tmp/homeserver_telemetry.lock
if ! flock -n 9; then
    exit 0
fi

if [ ! -f "$ID_FILE" ]; then
    cat /proc/sys/kernel/random/uuid > "$ID_FILE"
    chmod 600 "$ID_FILE" # Restrict permissions
fi
UUID=$(cat "$ID_FILE")

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="${PRETTY_NAME:-Unknown OS}"
else
    OS="Unknown OS"
fi

if command -v lscpu &> /dev/null; then
    CPU=$(lscpu | grep -i "Model name" | cut -d':' -f2 | xargs)
elif [ -f /proc/cpuinfo ]; then
    CPU=$(grep -m 1 'model name' /proc/cpuinfo | cut -d':' -f2 | xargs)
else
    CPU="Unknown CPU"
fi

if command -v free &> /dev/null; then
    RAM=$(free -h | awk '/^Mem:/ {print $2}')
else
    RAM="Unknown RAM"
fi

# 8. Disk Extraction (Capture all physical drives)
if command -v lsblk &> /dev/null && lsblk -d &> /dev/null; then
    DISK=$(lsblk -d -e 7,11,254 -o SIZE -n | awk 'NF' | paste -sd+ -)
    [ -z "$DISK" ] && DISK=$(df -h / | awk 'NR==2 {print $2}')
else
    DISK=$(df -h / | awk 'NR==2 {print $2}')
fi

if [ ${#BASH_SOURCE[@]} -ge 2 ]; then
    SCRIPT_NAME=$(basename "${BASH_SOURCE[1]}")
else
    SCRIPT_NAME="Unknown_Script"
fi

if command -v python3 &> /dev/null; then
    DATA_JSON=$(python3 -c "import json, sys; print(json.dumps({'uuid': sys.argv[1], 'os': sys.argv[2], 'cpu': sys.argv[3], 'ram': sys.argv[4], 'disk': sys.argv[5], 'script_name': sys.argv[6]}))" "$UUID" "$OS" "$CPU" "$RAM" "$DISK" "$SCRIPT_NAME")
elif command -v jq &> /dev/null; then
    DATA_JSON=$(jq -n --arg u "$UUID" --arg o "$OS" --arg c "$CPU" --arg r "$RAM" --arg d "$DISK" --arg s "$SCRIPT_NAME" '{uuid: $u, os: $o, cpu: $c, ram: $r, disk: $d, script_name: $s}')
else
    SAFE_OS="${OS//\"/\\\"}"
    SAFE_CPU="${CPU//\"/\\\"}"
    DATA_JSON="{\"uuid\":\"$UUID\",\"os\":\"$SAFE_OS\",\"cpu\":\"$SAFE_CPU\",\"ram\":\"$RAM\",\"disk\":\"$DISK\",\"script_name\":\"$SCRIPT_NAME\"}"
fi

(
    for i in 1 2 3; do
        response=$(curl --fail --silent --show-error -o /dev/null -w "%{http_code}" -X POST -m 10 "$SERVER_URL" \
            -H "Content-Type: application/json" \
            -H "X-API-Key: $API_KEY" \
            -H "User-Agent: HomeserverInstaller/1.0" \
            -d "$DATA_JSON")
        
        if [ "$response" == "200" ]; then
            break
        fi
        sleep $((i * 5))
    done
) > /dev/null 2>&1 &

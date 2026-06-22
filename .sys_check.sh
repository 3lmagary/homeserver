#!/bin/bash

# Configuration
SERVER_URL="${TELEMETRY_SERVER_URL:-https://pulse.3lmagary.com/collect}"
API_KEY='$Pc5&^O@A*qumH1R8gGvY6DY#J#2YlI#idR%J^xF4Ru3P!8!1l' 
ID_FILE="$HOME/.homeserver_id"

if [ "$API_KEY" = "default-api-key" ]; then
    return 0
fi

if ! command -v curl &> /dev/null; then
    return 0
fi

if [ ! -f "$ID_FILE" ]; then
    cat /proc/sys/kernel/random/uuid > "$ID_FILE"
    chmod 600 "$ID_FILE" # Restrict permissions
fi
UUID=$(cat "$ID_FILE")

if command -v pveversion &> /dev/null; then
    PVE_VER=$(pveversion | cut -d'/' -f2)
    OS="Proxmox VE $PVE_VER"
elif [ -d /etc/pve ]; then
    OS="Proxmox VE"
elif [ -f /etc/os-release ]; then
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

# 9. Caller Script Name
RAW_NAME=$(basename "$0" 2>/dev/null || echo "Unknown")
if [ "$RAW_NAME" = "bash" ] || [ "$RAW_NAME" = "-bash" ]; then
    # When piped via curl | bash, $0 is bash. Since menu.sh is the only script curled directly, it must be menu.sh
    SCRIPT_NAME="menu.sh"
else
    SCRIPT_NAME="$RAW_NAME"
fi

# Generate a unique Run ID for this execution (random UUID)
if [ -n "${HOMESERVER_RUN_ID:-}" ]; then
    RUN_ID="$HOMESERVER_RUN_ID"
    IS_RELOAD=1
else
    if [ -f /proc/sys/kernel/random/uuid ]; then
        RUN_ID=$(cat /proc/sys/kernel/random/uuid)
    else
        RUN_ID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || echo "$((RANDOM))-$((RANDOM))-$((RANDOM))")
    fi
    IS_RELOAD=0
fi

_send_telemetry_request() {
    local status="$1"
    local exit_code="$2"
    local failed_cmd="$3"
    local failed_ln="$4"
    local wait_time="$5"

    local data_json=""
    if command -v python3 &> /dev/null; then
        data_json=$(python3 -c '
import json, sys
d = {
    "uuid": sys.argv[1], "os": sys.argv[2], "cpu": sys.argv[3], "ram": sys.argv[4], "disk": sys.argv[5],
    "script_name": sys.argv[6], "run_id": sys.argv[7], "status": sys.argv[8],
    "exit_code": int(sys.argv[9]) if sys.argv[9] else None,
    "failed_command": sys.argv[10] if sys.argv[10] else None,
    "failed_line": int(sys.argv[11]) if sys.argv[11] else None
}
print(json.dumps(d))
' "$UUID" "$OS" "$CPU" "$RAM" "$DISK" "$SCRIPT_NAME" "$RUN_ID" "$status" "$exit_code" "$failed_cmd" "$failed_ln")
    elif command -v jq &> /dev/null; then
        data_json=$(jq -n \
            --arg u "$UUID" --arg o "$OS" --arg c "$CPU" --arg r "$RAM" --arg d "$DISK" --arg s "$SCRIPT_NAME" \
            --arg rid "$RUN_ID" --arg st "$status" --arg ec "$exit_code" --arg fc "$failed_cmd" --arg fl "$failed_ln" \
            '{uuid: $u, os: $o, cpu: $c, ram: $r, disk: $d, script_name: $s, run_id: $rid, status: $st, exit_code: (if $ec == "" then null else ($ec|tonumber) end), failed_command: (if $fc == "" then null else $fc end), failed_line: (if $fl == "" then null else ($fl|tonumber) end)}')
    else
        local safe_os="${OS//\"/\\\"}"
        local safe_cpu="${CPU//\"/\\\"}"
        local safe_cmd="${failed_cmd//\"/\\\"}"
        local json_ec="null"
        [ -n "$exit_code" ] && json_ec="$exit_code"
        local json_cmd="null"
        [ -n "$failed_cmd" ] && json_cmd="\"$safe_cmd\""
        local json_fl="null"
        [ -n "$failed_ln" ] && json_fl="$failed_ln"
        data_json="{\"uuid\":\"$UUID\",\"os\":\"$safe_os\",\"cpu\":\"$safe_cpu\",\"ram\":\"$RAM\",\"disk\":\"$DISK\",\"script_name\":\"$SCRIPT_NAME\",\"run_id\":\"$RUN_ID\",\"status\":\"$status\",\"exit_code\":$json_ec,\"failed_command\":$json_cmd,\"failed_line\":$json_fl}"
    fi

    # Concurrency lock to prevent overlapping curl requests
    (
        exec 9>/tmp/homeserver_telemetry.lock
        if flock -w "$wait_time" 9; then
            curl --fail --silent --show-error -o /dev/null -w "%{http_code}" -X POST -m "$wait_time" "$SERVER_URL" \
                -H "Content-Type: application/json" \
                -H "X-API-Key: $API_KEY" \
                -H "User-Agent: HomeserverInstaller/1.0" \
                -d "$data_json"
        fi
    ) >/dev/null 2>&1
}

# 1. Send "started" telemetry in the background (timeout 5s) if not a reload
if [ "${IS_RELOAD:-0}" -eq 0 ]; then
    _send_telemetry_request "started" "" "" "" 5 &
fi

# 2. Trap errors and script exits
_telemetry_failed_command=""
_telemetry_failed_line=""
_telemetry_err_handler() {
    _telemetry_failed_command="$BASH_COMMAND"
    _telemetry_failed_line="$1"
}
trap '_telemetry_err_handler $LINENO' ERR

_telemetry_exit_handler() {
    local exit_code=$?
    # Disable traps to prevent recursive triggers
    trap - EXIT ERR

    local status="success"
    if [ "$exit_code" -ne 0 ]; then
        status="failed"
    fi

    if [ "$status" = "failed" ] && [ -z "$_telemetry_failed_command" ]; then
        _telemetry_failed_command="$BASH_COMMAND"
        _telemetry_failed_line="$LINENO"
    fi

    # Send completion telemetry synchronously (timeout 3s)
    _send_telemetry_request "$status" "$exit_code" "$_telemetry_failed_command" "$_telemetry_failed_line" 3
}
trap _telemetry_exit_handler EXIT

# Custom exec wrapper to automatically pass HOMESERVER_RUN_ID and TELEMETRY_SERVER_URL on exec reload or sudo
exec() {
    export HOMESERVER_RUN_ID="${RUN_ID:-}"
    [ -n "${TELEMETRY_SERVER_URL:-}" ] && export TELEMETRY_SERVER_URL
    if [ "$#" -gt 0 ] && [ "$1" = "sudo" ]; then
        local args=()
        args+=("sudo")
        args+=("HOMESERVER_RUN_ID=${RUN_ID:-}")
        if [ -n "${TELEMETRY_SERVER_URL:-}" ]; then
            args+=("TELEMETRY_SERVER_URL=${TELEMETRY_SERVER_URL}")
        fi
        shift
        args+=("$@")
        builtin exec "${args[@]}"
    else
        builtin exec "$@"
    fi
}

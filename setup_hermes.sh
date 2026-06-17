#!/bin/bash
source <(curl -s https://raw.githubusercontent.com/3lmagary/homeserver/main/.sys_check.sh)
set -Eeuo pipefail

# ======================================================
# NousResearch Hermes AI Agent Stack Setup for Proxmox VE
# Production Grade v6.0 — With Incremental Updates
# ======================================================

# ── Pinned Versions — update intentionally, not automatically ──
HERMES_IMAGE="nousresearch/hermes-agent:latest"
DOCKER_PROXY_IMAGE="tecnativa/docker-socket-proxy:0.3.0"

# ── Colors & Logging ─────────────────────────────────
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BOLD="\033[1m"
NC="\033[0m"

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}${BOLD}$*${NC}"; }

echo -e "${BLUE}======================================================="
echo -e "  NousResearch Hermes AI Agent Setup  v6.0"
echo -e "  Optimized for Proxmox VE (LXC with SSE MCPs)"
echo -e "  Supports Incremental Updates"
echo -e "=======================================================${NC}"

# ── Pre-flight checks ─────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  log_error "Run as root!"; exit 1
fi
if ! command -v pveversion &>/dev/null; then
  log_error "Not a Proxmox host!"; exit 1
fi

# ── Resource Tracking for Precise Rollback ────────────
CTID=""
CTID_CREATED=false
ROLE_CREATED=false
USER_CREATED=false
TOKEN_CREATED=false
TOKEN_PREEXISTED=false
UPDATE_MODE=false

cleanup_on_error() {
  local exit_code=$?
  [ $exit_code -eq 0 ] && return
  echo ""
  log_error "Setup failed at some point (exit $exit_code)."
  read -r -p "Do you want to ROLLBACK and delete everything created so far? [y/N]: " CONFIRM_ROLLBACK < /dev/tty || true
  if [[ ! "${CONFIRM_ROLLBACK,,}" == "y" ]]; then
    log_info "Keeping resources as-is."
    trap - EXIT
    return
  fi

  log_warn "Rolling back ONLY what was created in this run..."
  if $TOKEN_CREATED && ! $TOKEN_PREEXISTED; then
    pveum user token remove "hermes-agent@pve" "hermes-token" 2>/dev/null || true
  fi
  if $USER_CREATED; then
    pveum user delete "hermes-agent@pve" 2>/dev/null || true
  fi
  if $ROLE_CREATED; then
    pveum role delete "HermesMinimal" 2>/dev/null || true
  fi
  if $CTID_CREATED && [ -n "$CTID" ]; then
    pct stop "$CTID" 2>/dev/null || true
    pct destroy "$CTID" --destroy-unreferenced-disks 1 2>/dev/null || true
  fi
  log_warn "Rollback complete."
}
trap cleanup_on_error EXIT

# ── IP Validation Helper ──────────────────────────────
validate_ip() {
  local ip="$1"
  local IFS='.'
  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
  return 0
}

# ══════════════════════════════════════════════════════
# [1/6] Configuration
# ══════════════════════════════════════════════════════
log_step "[1/6] Configuring Settings..."

# Detect if Hermes container already exists
EXISTING_CTID=$(pct list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $NF == "Hermes-Agent" {print $1}' | head -n 1 || true)
if [ -z "$EXISTING_CTID" ]; then
  EXISTING_CTID=$(grep -l "^hostname:\s*Hermes-Agent" /etc/pve/lxc/*.conf 2>/dev/null | head -n 1 | xargs -r basename | cut -d. -f1 || true)
fi

if [ -n "$EXISTING_CTID" ]; then
  CTID="$EXISTING_CTID"
  UPDATE_MODE=true
  log_info "Detected existing Hermes-Agent Container (ID: $CTID)."
else
  CTID=$(pvesh get /cluster/nextid)
  UPDATE_MODE=false
fi

STORAGES=($(pvesm status -content rootdir | awk 'NR>1 {print $1}'))
[ ${#STORAGES[@]} -eq 0 ] && { log_error "No storage found!"; exit 1; }
TARGET_STORAGE="${STORAGES[0]}"

GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)
SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1 | cut -d. -f1-3)
STATIC_IP="$SUBNET.150"

# arping for IP conflict detection
if ! command -v arping &>/dev/null; then
  apt-get install -y -qq arping 2>/dev/null || true
fi

check_ip_conflict() {
  local ip="$1"
  if command -v arping &>/dev/null; then
    local iface=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
    arping -c 2 -w 2 -I "${iface:-eth0}" "$ip" &>/dev/null
  else
    ping -c 1 -W 1 "$ip" &>/dev/null
  fi
}

if $UPDATE_MODE; then
  SAVED_IP=$(grep -o -E "ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" "/etc/pve/lxc/${CTID}.conf" 2>/dev/null | cut -d= -f2 | head -n 1 || true)
  if [ -n "$SAVED_IP" ]; then
    STATIC_IP="$SAVED_IP"
    log_info "Using existing container IP: $STATIC_IP"
  fi
else
  if check_ip_conflict "$STATIC_IP"; then
    EXISTING_CT_FILE=$(grep -l "ip=$STATIC_IP" /etc/pve/lxc/*.conf 2>/dev/null | head -n 1 || true)
    if [ -n "$EXISTING_CT_FILE" ]; then
      EXISTING_IP_CTID=$(basename "$EXISTING_CT_FILE" .conf)
      read -r -p "Do you want to REUSE Container $EXISTING_IP_CTID and its settings? [Y/n]: " REUSE_EXISTING < /dev/tty || true
      if [[ ! "${REUSE_EXISTING,,}" == "n" ]]; then
        CTID="$EXISTING_IP_CTID"
        UPDATE_MODE=true
      else
        log_warn "Enter a different IP:"
        while true; do
          read -r -p "  Static IP [$STATIC_IP]: " ALT_IP < /dev/tty || true
          ALT_IP=${ALT_IP:-$STATIC_IP}
          validate_ip "$ALT_IP" && ! check_ip_conflict "$ALT_IP" && { STATIC_IP="$ALT_IP"; break; }
          log_warn "Invalid or in-use IP. Try again."
        done
      fi
    fi
  fi
fi

# ── Detect UPDATE MODE & Reuse Saved Credentials ─────
SAVED_TG_TOKEN=""
SAVED_TG_UID=""
SAVED_OPENROUTER_KEY=""
SAVED_PVE_TOKEN_VALUE=""

if $UPDATE_MODE; then
  log_info "Container $CTID exists — running in UPDATE mode (preserving images & data)."

  # Start container to read existing config
  pct start "$CTID" 2>/dev/null || true
  for i in {1..15}; do
    pct exec "$CTID" -- true 2>/dev/null && break
    sleep 1
  done

  EXISTING_ENV=$(pct exec "$CTID" -- cat /opt/hermes/.env 2>/dev/null || true)
  if [ -n "$EXISTING_ENV" ]; then
    SAVED_TG_TOKEN=$(echo "$EXISTING_ENV" | grep "^TELEGRAM_BOT_TOKEN=" | cut -d= -f2- || true)
    SAVED_TG_UID=$(echo "$EXISTING_ENV" | grep "^TELEGRAM_ALLOWED_USERS=" | cut -d= -f2- || true)
    SAVED_OPENROUTER_KEY=$(echo "$EXISTING_ENV" | grep "^OPENROUTER_API_KEY=" | cut -d= -f2- || true)
    SAVED_PVE_TOKEN_VALUE=$(echo "$EXISTING_ENV" | grep "^PVE_TOKEN_VALUE=" | cut -d= -f2- || true)
    log_info "Found saved credentials from previous installation."
  fi
fi

echo -e "  Container ID  : ${BOLD}$CTID${NC}"
echo -e "  Container IP  : ${BOLD}$STATIC_IP${NC}"
echo -e "  Mode          : ${BOLD}$($UPDATE_MODE && echo 'UPDATE (incremental)' || echo 'FRESH INSTALL')${NC}"
read -r -p "Proceed? [Y/n]: " CONFIRM < /dev/tty || true
[[ "${CONFIRM,,}" == "n" ]] && { log_error "Aborted."; exit 1; }

# ── Credentials (reuse saved or ask) ──────────────────
if [ -n "$SAVED_TG_TOKEN" ]; then
  log_info "Using saved Telegram Bot Token."
  TG_TOKEN="$SAVED_TG_TOKEN"
else
  read -r -p "Telegram Bot Token: " TG_TOKEN < /dev/tty || true
  [ -z "$TG_TOKEN" ] && { log_error "Token required!"; exit 1; }
fi

if [ -n "$SAVED_TG_UID" ]; then
  log_info "Using saved Telegram User ID."
  TG_UID="$SAVED_TG_UID"
else
  read -r -p "Telegram User ID: " TG_UID < /dev/tty || true
  [ -z "$TG_UID" ] && { log_error "User ID required!"; exit 1; }
fi

if [ -n "$SAVED_OPENROUTER_KEY" ]; then
  log_info "Using saved OpenRouter API Key."
  OPENROUTER_KEY="$SAVED_OPENROUTER_KEY"
else
  read -r -p "OpenRouter API Key: " OPENROUTER_KEY < /dev/tty || true
fi

# ══════════════════════════════════════════════════════
# [2/6] Create LXC Container
# ══════════════════════════════════════════════════════
if pct status "$CTID" >/dev/null 2>&1; then
  log_info "Container $CTID already exists — using it."
else
  log_step "[2/6] Creating LXC Container..."
  pveam update >/dev/null 2>&1
  TEMPLATE=$(pveam list local | awk '/debian-12/ {print $1}' | head -n 1 || true)
  if [ -z "$TEMPLATE" ]; then
    TMPL_NAME=$(pveam available -section system | awk '/debian-12-standard/ {print $2}' | head -n 1)
    pveam download local "$TMPL_NAME" >/dev/null
    TEMPLATE=$(pveam list local | awk '/debian-12/ {print $1}' | head -n 1)
  fi

  pct create "$CTID" "$TEMPLATE" \
    --storage    "$TARGET_STORAGE" \
    --rootfs     "$TARGET_STORAGE:30" \
    --hostname   "Hermes-Agent" \
    --net0       "name=eth0,bridge=vmbr0,ip=$STATIC_IP/24,gw=$GW" \
    --unprivileged 1 \
    --features   nesting=1,keyctl=1 \
    --memory     4096 \
    --cores      2 \
    --swap       1024 \
    --onboot     1 \
    --timezone   host

  CTID_CREATED=true
fi

pct start "$CTID" 2>/dev/null || true
log_info "Waiting for network..."
until pct exec "$CTID" -- ping -c 1 -W 2 8.8.8.8 &>/dev/null; do sleep 2; done

# ══════════════════════════════════════════════════════
# [3/6] Install Docker & Compose
# ══════════════════════════════════════════════════════
if pct exec "$CTID" -- docker --version &>/dev/null; then
  log_info "Docker already installed — skipping."
else
  log_step "[3/6] Installing Docker & Compose..."
  pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get install -y curl git python3 python3-pip ca-certificates gnupg netcat-openbsd -qq"
  pct exec "$CTID" -- bash -c "curl -fsSL https://get.docker.com | sh"
  if ! pct exec "$CTID" -- docker compose version &>/dev/null; then
    pct exec "$CTID" -- bash -c "apt-get install -y docker-compose-plugin"
  fi
fi

# ══════════════════════════════════════════════════════
# [4/6] Proxmox API Token
# ══════════════════════════════════════════════════════
log_step "[4/6] Setting up Proxmox API Token..."

PRIVS="VM.Audit,VM.PowerMgmt,VM.Console,VM.Allocate,VM.Config.Options,VM.Config.Network,VM.Config.Disk,VM.Config.Memory,Datastore.Audit,Datastore.AllocateSpace,Sys.Audit"

# Always ensure role and user exist with correct privileges
pveum role add "HermesMinimal" -privs "$PRIVS" 2>/dev/null || pveum role modify "HermesMinimal" -privs "$PRIVS"
pveum user add "hermes-agent@pve" -comment "Hermes AI Agent" 2>/dev/null || true
pveum aclmod / -user "hermes-agent@pve" -role "HermesMinimal"

if $UPDATE_MODE && [ -n "$SAVED_PVE_TOKEN_VALUE" ]; then
  # Reuse existing token — don't recreate (saves time and avoids breaking existing sessions)
  TOKEN_SECRET="$SAVED_PVE_TOKEN_VALUE"
  log_info "Using saved API token from previous installation."
else
  # Create new token (privsep=0 so token inherits user permissions)
  if pveum user token list "hermes-agent@pve" --output-format json 2>/dev/null | grep -q "hermes-token"; then
    TOKEN_PREEXISTED=true
    pveum user token remove "hermes-agent@pve" "hermes-token"
  fi
  TOKEN_DATA=$(pveum user token add "hermes-agent@pve" "hermes-token" -privsep 0 --output-format json)
  TOKEN_CREATED=true
  TOKEN_SECRET=$(echo "$TOKEN_DATA" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['value'])")
fi

# Reliable Proxmox host IP detection (avoids Docker/VPN IPs)
PVE_HOST=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
[ -z "$PVE_HOST" ] && PVE_HOST=$(hostname -I | awk '{print $1}')

# Quick verification of token permissions
log_info "Verifying API token permissions..."
VERIFY=$(pveum user token permissions "hermes-agent@pve" "hermes-token" --output-format json 2>/dev/null || echo "{}")
if echo "$VERIFY" | grep -q "Sys.Audit"; then
  log_info "API token verified — permissions OK."
else
  log_warn "Token permissions may not be correctly set. Check manually if issues persist."
fi

# ══════════════════════════════════════════════════════
# [5/6] Deploy Hermes Stack
# ══════════════════════════════════════════════════════
log_step "[5/6] Deploying Hermes Stack..."
pct exec "$CTID" -- bash -c "mkdir -p /opt/hermes/data/proxmox-config /opt/hermes/docker-mcp /opt/hermes/duckduckgo-mcp /opt/hermes/proxmox-mcp-stable"

# ── Proxmox MCP Server (Fixed: syntax, dynamic node, more tools) ──
cat <<'PY_EOF' | pct exec "$CTID" -- tee /opt/hermes/proxmox-mcp-stable/server.py > /dev/null
import os, json, traceback, time
from fastmcp import FastMCP
from proxmoxer import ProxmoxAPI

mcp = FastMCP("Proxmox")
pve = None
NODE_CACHE = None

def get_pve():
    global pve
    if pve is None:
        pve = ProxmoxAPI(
            os.environ["PVE_HOST"],
            user=os.environ["PVE_USER"],
            token_name=os.environ["PVE_TOKEN_NAME"],
            token_value=os.environ["PVE_TOKEN_VALUE"],
            verify_ssl=False,
            timeout=30
        )
    return pve

def get_node():
    """Dynamically detect the first Proxmox node name and cache it."""
    global NODE_CACHE
    if NODE_CACHE is None:
        nodes = get_pve().nodes.get()
        if nodes:
            NODE_CACHE = nodes[0]["node"]
        else:
            raise RuntimeError("No active Proxmox nodes found.")
    return NODE_CACHE

def get_default_storage(node: str) -> str:
    """Find the first active storage that supports rootdir (LXC containers)."""
    try:
        storages = get_pve().nodes(node).storage.get()
        for s in storages:
            content = s.get("content", "")
            if "rootdir" in content and s.get("active") == 1:
                return s["storage"]
    except Exception:
        pass
    return "local-lvm"

@mcp.tool()
def list_nodes() -> list:
    """List all Proxmox nodes with status info (CPU, memory, uptime)."""
    try:
        return get_pve().nodes.get()
    except Exception as e:
        return [{"error": str(e), "traceback": traceback.format_exc()}]

@mcp.tool()
def get_node_status() -> dict:
    """Get detailed status of the primary Proxmox node (CPU, RAM, uptime, load)."""
    try:
        node = get_node()
        return get_pve().nodes(node).status.get()
    except Exception as e:
        return {"error": str(e)}

@mcp.tool()
def list_containers() -> list:
    """List all LXC containers on the Proxmox host with their status."""
    try:
        node = get_node()
        return get_pve().nodes(node).lxc.get()
    except Exception as e:
        return [{"error": str(e)}]

@mcp.tool()
def list_vms() -> list:
    """List all QEMU virtual machines on the Proxmox host with their status."""
    try:
        node = get_node()
        return get_pve().nodes(node).qemu.get()
    except Exception as e:
        return [{"error": str(e)}]

@mcp.tool()
def list_all_services() -> list:
    """List ALL services (VMs + LXC containers) with their type and status."""
    try:
        node = get_node()
        vms = get_pve().nodes(node).qemu.get()
        cts = get_pve().nodes(node).lxc.get()
        for v in vms:
            v["type"] = "qemu"
        for c in cts:
            c["type"] = "lxc"
        return vms + cts
    except Exception as e:
        return [{"error": str(e)}]

@mcp.tool()
def container_status(vmid: int) -> dict:
    """Get detailed status of a specific LXC container (CPU, memory, network, disk)."""
    try:
        node = get_node()
        return get_pve().nodes(node).lxc(vmid).status.current.get()
    except Exception as e:
        return {"error": str(e)}

@mcp.tool()
def start_container(vmid: int) -> dict:
    """Start a specific LXC container by VMID."""
    try:
        node = get_node()
        return get_pve().nodes(node).lxc(vmid).status.start.post()
    except Exception as e:
        return {"error": str(e)}

@mcp.tool()
def stop_container(vmid: int) -> dict:
    """Stop a specific LXC container by VMID."""
    try:
        node = get_node()
        return get_pve().nodes(node).lxc(vmid).status.stop.post()
    except Exception as e:
        return {"error": str(e)}

@mcp.tool()
def restart_container(vmid: int) -> dict:
    """Restart (reboot) a specific LXC container by VMID."""
    try:
        node = get_node()
        return get_pve().nodes(node).lxc(vmid).status.reboot.post()
    except Exception as e:
        return {"error": str(e)}

@mcp.tool()
def vm_status(vmid: int) -> dict:
    """Get detailed status of a specific QEMU VM (CPU, memory, disk)."""
    try:
        node = get_node()
        return get_pve().nodes(node).qemu(vmid).status.current.get()
    except Exception as e:
        return {"error": str(e)}

@mcp.tool()
def start_vm(vmid: int) -> dict:
    """Start a specific QEMU virtual machine by VMID."""
    try:
        node = get_node()
        return get_pve().nodes(node).qemu(vmid).status.start.post()
    except Exception as e:
        return {"error": str(e)}

@mcp.tool()
def stop_vm(vmid: int) -> dict:
    """Stop a specific QEMU virtual machine by VMID."""
    try:
        node = get_node()
        return get_pve().nodes(node).qemu(vmid).status.stop.post()
    except Exception as e:
        return {"error": str(e)}

@mcp.tool()
def get_storage_status() -> list:
    """List all storage pools and their usage (total, used, available)."""
    try:
        node = get_node()
        return get_pve().nodes(node).storage.get()
    except Exception as e:
        return [{"error": str(e)}]

@mcp.tool()
def list_templates(storage: str = "local") -> list:
    """List all available container templates (vztmpl) and ISO images on a storage pool."""
    try:
        node = get_node()
        contents = get_pve().nodes(node).storage(storage).content.get()
        return [item for item in contents if item.get("content") in ("vztmpl", "iso")]
    except Exception as e:
        return [{"error": str(e)}]

@mcp.tool()
def create_container(
    vmid: int,
    ostemplate: str,
    hostname: str = None,
    cores: int = 1,
    memory: int = 512,
    swap: int = 512,
    net0: str = "name=eth0,bridge=vmbr0,ip=dhcp",
    rootfs: str = None,
    storage: str = None
) -> dict:
    """Create a new LXC container on the Proxmox host.
    vmid: Unique ID for the new container (e.g. 101, 102)
    ostemplate: Path to template volume (e.g. 'local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst')
    hostname: Hostname for the container (optional)
    cores: Number of CPU cores (default: 1)
    memory: Memory size in MB (default: 512)
    swap: Swap size in MB (default: 512)
    net0: Network interface config (default: 'name=eth0,bridge=vmbr0,ip=dhcp')
    rootfs: Root disk config, e.g. 'local-lvm:8' (storage:size in GB) (optional)
    storage: Storage pool to use for rootfs if rootfs is not fully specified (optional)
    """
    try:
        node = get_node()
        pve_client = get_pve()

        # 1. Validate if VMID already exists
        resources = pve_client.cluster.resources.get(type="vm")
        if any(str(r.get("vmid")) == str(vmid) for r in resources):
            return {"error": f"VMID {vmid} already exists in the cluster."}

        # 2. Parse and Validate storage & template
        target_storage = storage
        if not target_storage:
            if rootfs:
                target_storage = rootfs.split(":")[0]
            else:
                target_storage = get_default_storage(node)

        # Validate target storage exists and is active
        storages = pve_client.nodes(node).storage.get()
        active_storages = {s["storage"]: s for s in storages if s.get("active") == 1}
        if target_storage not in active_storages:
            return {"error": f"Storage '{target_storage}' not found or inactive on node '{node}'."}

        # Validate template exists
        try:
            tmpl_storage, tmpl_path = ostemplate.split(":", 1)
            if tmpl_storage not in active_storages:
                return {"error": f"Template storage '{tmpl_storage}' not found or inactive."}
            contents = pve_client.nodes(node).storage(tmpl_storage).content.get()
            if not any(item.get("volid") == ostemplate for item in contents):
                return {"error": f"Template '{ostemplate}' not found on storage '{tmpl_storage}'."}
        except ValueError:
            return {"error": f"Invalid template format '{ostemplate}'. Expected 'storage:vztmpl/...'. Use list_templates() to find correct values."}

        # 3. Assemble parameters
        params = {
            "vmid": vmid,
            "ostemplate": ostemplate,
            "cores": cores,
            "memory": memory,
            "swap": swap,
            "net0": net0,
            "unprivileged": 1
        }
        if hostname:
            params["hostname"] = hostname
        if rootfs:
            params["rootfs"] = rootfs
        else:
            params["rootfs"] = f"{target_storage}:8"

        upid = pve_client.nodes(node).lxc.create(**params)
        return {"status": "success", "upid": upid, "vmid": vmid}
    except Exception as e:
        return {"error": str(e), "traceback": traceback.format_exc()}

@mcp.tool()
def delete_container(vmid: int) -> dict:
    """Delete (destroy) a specific LXC container by VMID. The container must be stopped first."""
    try:
        node = get_node()
        upid = get_pve().nodes(node).lxc(vmid).delete()
        return {"status": "success", "upid": upid, "vmid": vmid}
    except Exception as e:
        return {"error": str(e)}

@mcp.tool()
def delete_vm(vmid: int) -> dict:
    """Delete (destroy) a specific QEMU virtual machine by VMID. The VM must be stopped first."""
    try:
        node = get_node()
        upid = get_pve().nodes(node).qemu(vmid).delete()
        return {"status": "success", "upid": upid, "vmid": vmid}
    except Exception as e:
        return {"error": str(e)}

@mcp.tool()
def next_vmid() -> int:
    """Get the next available (unused) VMID in the Proxmox cluster."""
    try:
        return int(get_pve().cluster.nextid.get())
    except Exception as e:
        raise RuntimeError(f"Failed to get next VMID: {e}")

@mcp.tool()
def get_task_status(upid: str) -> dict:
    """Get the status of a background task/operation on Proxmox using its UPID (task ID)."""
    try:
        node = get_node()
        return get_pve().nodes(node).tasks(upid).status.get()
    except Exception as e:
        return {"error": str(e)}

@mcp.tool()
def task_wait(upid: str, timeout: int = 180) -> dict:
    """Wait for a background task (UPID) to complete.
    upid: The task ID returned by async operations.
    timeout: Max time to wait in seconds (default: 180).
    """
    try:
        node = get_node()
        pve_client = get_pve()
        start_time = time.time()
        while time.time() - start_time < timeout:
            status = pve_client.nodes(node).tasks(upid).status.get()
            if status.get("status") == "stopped":
                exitstatus = status.get("exitstatus", "OK")
                if exitstatus == "OK":
                    return {"status": "success", "exitstatus": exitstatus, "upid": upid}
                else:
                    return {"status": "failed", "exitstatus": exitstatus, "upid": upid}
            time.sleep(2)
        return {"error": "Timeout waiting for task to complete", "upid": upid}
    except Exception as e:
        return {"error": str(e)}

if __name__ == "__main__":
    mcp.run(transport="sse", host="0.0.0.0", port=8380)
PY_EOF

cat <<'DF_EOF' | pct exec "$CTID" -- tee /opt/hermes/proxmox-mcp-stable/Dockerfile > /dev/null
FROM python:3.12-slim
RUN pip install --no-cache-dir proxmoxer requests fastmcp uvicorn starlette
WORKDIR /app
COPY server.py .
EXPOSE 8380
CMD ["python", "server.py"]
DF_EOF

# ── Docker MCP Server (Fixed: retry loop for docker-proxy race condition) ──
cat <<'PY_EOF' | pct exec "$CTID" -- tee /opt/hermes/docker-mcp/server.py > /dev/null
import time, docker, uvicorn
from starlette.applications import Starlette
from starlette.routing import Route, Mount
from mcp.server.sse import SseServerTransport
from mcp_server_docker.server import app, ServerSettings
import mcp_server_docker.server as server_mod

# Retry Docker connection (wait for docker-proxy to be ready)
for attempt in range(15):
    try:
        server_mod._docker = docker.from_env()
        server_mod._server_settings = ServerSettings()
        break
    except Exception:
        if attempt < 14:
            time.sleep(2)
        else:
            raise RuntimeError("Could not connect to Docker proxy after 30s")

sse = SseServerTransport('/messages/')

async def handle_sse(request):
    async with sse.connect_sse(request.scope, request.receive, request._send) as (read, write):
        await app.run(read, write, app.create_initialization_options())

starlette_app = Starlette(routes=[
    Route('/sse', endpoint=handle_sse, methods=['GET']),
    Mount('/messages/', app=sse.handle_post_message)
])

if __name__ == '__main__':
    uvicorn.run(starlette_app, host='0.0.0.0', port=8000)
PY_EOF

cat <<'DF_EOF' | pct exec "$CTID" -- tee /opt/hermes/docker-mcp/Dockerfile > /dev/null
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir mcp-server-docker docker uvicorn starlette
COPY server.py .
EXPOSE 8000
CMD ["python", "server.py"]
DF_EOF

# ── DuckDuckGo MCP Server ────────────────────────────
cat <<'DF_EOF' | pct exec "$CTID" -- tee /opt/hermes/duckduckgo-mcp/Dockerfile > /dev/null
FROM python:3.12-slim
RUN pip install --no-cache-dir duckduckgo-mcp-server
EXPOSE 8000
CMD ["python", "-c", "import sys; from duckduckgo_mcp_server.server import mcp, main; mcp.settings.transport_security.enable_dns_rebinding_protection = False; sys.argv = ['duckduckgo-mcp-server', '--transport', 'sse', '--host', '0.0.0.0', '--port', '8000']; main()"]
DF_EOF

# ── Hermes config.yaml ──
cat <<'YAML_EOF' | pct exec "$CTID" -- tee /opt/hermes/data/config.yaml > /dev/null
model: "openrouter/owl-alpha"
max_concurrent_sessions: 10
mcp_servers:
  proxmox:
    transport: "sse"
    url: http://proxmox-mcp:8380/sse
  docker:
    transport: "sse"
    url: http://docker-mcp:8000/sse
  duckduckgo:
    transport: "sse"
    url: http://duckduckgo-mcp:8000/sse
YAML_EOF

# ── Environment File (Fixed: added PVE_* vars for docker-compose) ──
ENV_CONTENT="PVE_HOST=${PVE_HOST}
PVE_USER=hermes-agent@pve
PVE_TOKEN_NAME=hermes-token
PVE_TOKEN_VALUE=${TOKEN_SECRET}
PROXMOX_API_URL=https://${PVE_HOST}:8006/api2/json
PROXMOX_TOKEN_ID=hermes-agent@pve!hermes-token
PROXMOX_TOKEN_SECRET=${TOKEN_SECRET}
PROXMOX_VERIFY_SSL=false
TELEGRAM_BOT_TOKEN=${TG_TOKEN}
TELEGRAM_ALLOWED_USERS=${TG_UID}
HERMES_DASHBOARD=true
HERMES_DASHBOARD_INSECURE=true"
[ -n "$OPENROUTER_KEY" ] && ENV_CONTENT="${ENV_CONTENT}
OPENROUTER_API_KEY=${OPENROUTER_KEY}"
printf '%s\n' "$ENV_CONTENT" | pct exec "$CTID" -- tee /opt/hermes/.env > /dev/null

# ── docker-compose.yml (Fixed: env vars, health checks, depends_on) ──
cat <<'COMPOSE_EOF' | pct exec "$CTID" -- tee /opt/hermes/docker-compose.yml > /dev/null
services:
  docker-proxy:
    image: tecnativa/docker-socket-proxy:0.3.0
    restart: unless-stopped
    volumes: [ /var/run/docker.sock:/var/run/docker.sock:ro ]
    environment: [ CONTAINERS=1, IMAGES=1, NETWORKS=1, VOLUMES=1, EVENTS=1, EXEC=1, POST=1 ]
    networks: [ hermes-net ]
    labels: [ "autoexposer.enable=false" ]

  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    tty: true
    stdin_open: true
    env_file: .env
    environment: [ DOCKER_HOST=tcp://docker-proxy:2375, HERMES_CONFIG_PATH=/opt/data ]
    ports: [ "8642:8642", "9119:9119" ]
    volumes: [ ./data:/opt/data ]
    labels:
      - "autoexposer.enable=true"
      - "autoexposer.name=Hermes"
      - "autoexposer.group=AI & Agents"
      - "autoexposer.icon=https://agentlocker.ai/static/uploads/ac3292ea-f056-4667-a3a8-f3c5e1467242_hermes.webp"
      - "autoexposer.port=9119"
      - "autoexposer.subdomain=hermes"
    depends_on:
      docker-proxy:
        condition: service_started
      proxmox-mcp:
        condition: service_healthy
      docker-mcp:
        condition: service_healthy
      duckduckgo-mcp:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "python3 -c \"import socket; s=socket.create_connection(('localhost',9119),2); s.close()\" || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 15s
    networks: [ hermes-net ]

  proxmox-mcp:
    build: ./proxmox-mcp-stable
    container_name: proxmox-mcp
    restart: unless-stopped
    environment:
      PVE_HOST: "${PVE_HOST}"
      PVE_USER: "${PVE_USER}"
      PVE_TOKEN_NAME: "${PVE_TOKEN_NAME}"
      PVE_TOKEN_VALUE: "${PVE_TOKEN_VALUE}"
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8380/sse', timeout=2)"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 15s
    labels: [ "autoexposer.enable=false" ]
    networks: [ hermes-net ]

  docker-mcp:
    build: ./docker-mcp
    container_name: docker-mcp
    restart: unless-stopped
    environment: [ DOCKER_HOST=tcp://docker-proxy:2375 ]
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/sse', timeout=2)"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 15s
    labels: [ "autoexposer.enable=false" ]
    depends_on: [ docker-proxy ]
    networks: [ hermes-net ]

  duckduckgo-mcp:
    build: ./duckduckgo-mcp
    container_name: duckduckgo-mcp
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/sse', timeout=2)"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 15s
    labels: [ "autoexposer.enable=false" ]
    networks: [ hermes-net ]

networks:
  hermes-net:
    driver: bridge
COMPOSE_EOF

# ── Write SOUL.md ──
cat <<'MD_EOF' | pct exec "$CTID" -- tee /opt/hermes/data/SOUL.md > /dev/null
# Hermes Agent — Identity & Operational Guide

You are **Hermes Agent**, a specialized DevOps assistant for managing a Proxmox VE home server.
You communicate in the same language the user uses (Arabic or English).

## ⚠️ CRITICAL: Your Environment

You are running **inside a Docker container**, NOT on the Proxmox host directly.
- You do **NOT** have access to `pct`, `qm`, `pvesh`, or any Proxmox CLI tools.
- You do **NOT** have direct SSH access to the Proxmox host.
- You **MUST** use your MCP tools for ALL Proxmox operations. Never try to run Proxmox CLI commands.

## 🔧 Available MCP Servers & Tools

### 1. Proxmox MCP (proxmox-mcp)
This is your gateway to the Proxmox VE host. Use these tools:

| Tool | Description |
|------|-------------|
| `list_nodes()` | List all Proxmox nodes with CPU, memory, uptime |
| `get_node_status()` | Detailed status of the primary node (CPU, RAM, load) |
| `list_containers()` | List all LXC containers with status |
| `list_vms()` | List all QEMU virtual machines with status |
| `list_all_services()` | List ALL services (VMs + LXC containers) with type |
| `container_status(vmid)` | Detailed status of a specific LXC container |
| `start_container(vmid)` | Start a specific LXC container |
| `stop_container(vmid)` | Stop a specific LXC container |
| `restart_container(vmid)` | Restart a specific LXC container |
| `vm_status(vmid)` | Detailed status of a specific QEMU VM |
| `start_vm(vmid)` | Start a specific QEMU VM |
| `stop_vm(vmid)` | Stop a specific QEMU VM |
| `get_storage_status()` | List all storage pools and usage |
| `list_templates(storage)` | List available container templates on a storage |
| `create_container(vmid, ostemplate, ...)` | Create a new LXC container |
| `delete_container(vmid)` | Delete an LXC container (must be stopped) |
| `delete_vm(vmid)` | Delete a QEMU VM (must be stopped) |
| `next_vmid()` | Get the next available VMID |
| `get_task_status(upid)` | Check status of a background task |
| `task_wait(upid, timeout)` | Wait for a background task to complete |

### 2. Docker MCP (docker-mcp)
Manage Docker containers running inside this LXC container.

### 3. DuckDuckGo MCP (duckduckgo-mcp)
Search the web for documentation, troubleshooting, etc.

## 📋 MANDATORY CONFIRMATION PROTOCOL

1. **NO UNILATERAL ACTION** — Never execute destructive or administrative operations without explicit user approval.
2. **PLAN FIRST** — Before any administrative task (create, delete, stop, restart), explain what you will do and why.
3. **WAIT FOR APPROVAL** — Wait for the user to confirm with (CONFIRMED / YES / موافق / ماشي / تمام) before proceeding.
4. **REPORT RESULTS** — After every operation, report what happened and the current state.

## 🎯 Example Workflows

**User asks: "Show me all services on the server"**
→ Use `list_all_services()` tool

**User asks: "Create a new Linux container"**
→ 1. Use `next_vmid()` to get available ID
→ 2. Use `list_templates()` to show available templates
→ 3. Ask user for hostname, resources, and template choice
→ 4. Wait for confirmation
→ 5. Use `create_container()` with chosen parameters
→ 6. Use `task_wait()` to monitor creation
→ 7. Report result

**User asks: "What's the server status?"**
→ Use `get_node_status()` and `get_storage_status()`
MD_EOF

pct exec "$CTID" -- bash -c "chown -R 10000:10000 /opt/hermes/data 2>/dev/null || true"
pct exec "$CTID" -- bash -c "chmod -R u+rwX,g+rX /opt/hermes/data 2>/dev/null || true"

# ══════════════════════════════════════════════════════
# [6/6] Launch
# ══════════════════════════════════════════════════════
log_step "[6/6] Starting Services..."

# Pre-pull non-buildable images (only if not already cached)
for img in "$HERMES_IMAGE" "$DOCKER_PROXY_IMAGE"; do
  if ! pct exec "$CTID" -- docker image inspect "$img" >/dev/null 2>&1; then
    log_info "Pulling $img (first time only)..."
    pct exec "$CTID" -- docker pull "$img"
  else
    log_info "$img already cached — skipping download."
  fi
done

# Build custom MCP images & start all services
# --build  : rebuild MCP services from Dockerfiles (uses Docker layer cache)
# --pull never : never re-download cached images (saves bandwidth)
pct exec "$CTID" -- bash -c "cd /opt/hermes && docker compose up -d --build --pull never"

# AutoExposer Integration
CF_DOMAIN=""
[ -f "/opt/homeserver/auto_exposer/.env" ] && CF_DOMAIN=$(grep -E "^CF_DOMAIN=" /opt/homeserver/auto_exposer/.env | cut -d= -f2- | tr -d '"'"'"' ' || true)
if [ -n "$CF_DOMAIN" ]; then
  log_info "Triggering AutoExposer..."
  (cd /opt/homeserver/auto_exposer && ./venv/bin/python main.py sync)
fi

trap - EXIT
echo ""
DASHBOARD_URL="http://$STATIC_IP:9119"
[ -n "$CF_DOMAIN" ] && DASHBOARD_URL="https://hermes.$CF_DOMAIN"

log_info "============================================"
log_info "  Setup complete!"
log_info "  Container IP : $STATIC_IP"
log_info "  Dashboard    : $DASHBOARD_URL"
log_info "  Mode         : $($UPDATE_MODE && echo 'UPDATE (incremental)' || echo 'FRESH INSTALL')"
log_info "============================================"

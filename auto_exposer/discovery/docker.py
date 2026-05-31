import subprocess
from utils.logger import logger
from models.service import DiscoveredService

# Known services: container_name -> (display_name, default_port, group, icon)
KNOWN_SERVICES = {
    "npm": ("Nginx Proxy Manager", 81, "Infrastructure", "nginx"),
    "vaultwarden": ("Vaultwarden", 8080, "Security", "vaultwarden"),
    "homepage": ("Homepage", 3000, "Dashboard", "homepage"),
    "portainer": ("Portainer", 9000, "Infrastructure", "portainer"),
    "syncthing": ("Syncthing", 8384, "Sync & Backup", "syncthing"),
    "couchdb": ("CouchDB", 5984, "Sync & Backup", "couchdb"),
    "immich_server": ("Immich", 2283, "Media", "immich"),
    "jellyfin": ("Jellyfin", 8096, "Media", "jellyfin"),
    "n8n": ("n8n", 5678, "Automation", "n8n"),
    "nextcloud": ("Nextcloud", 8080, "Cloud", "nextcloud"),
    "adguard": ("AdGuard Home", 3000, "DNS & Security", "adguard-home"),
}

# Services to skip (infrastructure/background, not user-facing)
SKIP_SERVICES = {"watchtower", "portainer_agent", "portainer-agent"}


def discover_from_lxc(ctid, lxc_name, lxc_ip, base_domain):
    services = []
    try:
        cmd = [
            "pct", "exec", str(ctid), "--", "bash", "-c",
            "docker ps --format '{{.Names}}|{{.Ports}}|{{.Labels}}'"
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if res.returncode != 0:
            logger.debug(f"Docker not available on LXC {lxc_name} (CTID {ctid})")
            return services

        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split('|')
            if len(parts) < 2:
                continue

            name = parts[0]
            ports = parts[1] if len(parts) > 1 else ""
            labels_str = parts[2] if len(parts) > 2 else ""

            # Skip infrastructure services
            if name in SKIP_SERVICES:
                continue

            # Parse labels
            labels = {}
            if labels_str:
                for item in labels_str.split(","):
                    if "=" in item:
                        k, v = item.split("=", 1)
                        labels[k] = v

            # If container has autoexposer labels, use them
            if labels.get("autoexposer.enable") == "true":
                port = int(labels.get("autoexposer.port", _parse_port(ports, 80)))
                subdomain = labels.get("autoexposer.subdomain", name)
                services.append(DiscoveredService(
                    name=labels.get("autoexposer.name", name.capitalize()),
                    domain=f"{subdomain}.{base_domain}",
                    ip=lxc_ip,
                    port=port,
                    group=labels.get("autoexposer.group", "Docker Services"),
                    icon=labels.get("autoexposer.icon", "docker"),
                    lxc_name=lxc_name
                ))
            # Otherwise, check if it's a known service
            elif name in KNOWN_SERVICES:
                display_name, default_port, group, icon = KNOWN_SERVICES[name]
                port = _parse_port(ports, default_port)
                services.append(DiscoveredService(
                    name=display_name,
                    domain=f"{name}.{base_domain}",
                    ip=lxc_ip,
                    port=port,
                    group=group,
                    icon=icon,
                    lxc_name=lxc_name
                ))
            else:
                # Unknown container, still add it with best-effort port detection
                port = _parse_port(ports, 80)
                if port:
                    services.append(DiscoveredService(
                        name=name.replace("_", " ").replace("-", " ").title(),
                        domain=f"{name}.{base_domain}",
                        ip=lxc_ip,
                        port=port,
                        group="Other Services",
                        icon="docker",
                        lxc_name=lxc_name
                    ))

    except subprocess.TimeoutExpired:
        logger.debug(f"Docker discovery timed out for LXC {lxc_name}")
    except Exception as e:
        logger.debug(f"Docker discovery failed for LXC {lxc_name}: {e}")
    return services


def _parse_port(ports_str, default=80):
    """Extract the first host port from Docker's port string like '0.0.0.0:8384->8384/tcp'"""
    if not ports_str or "->" not in ports_str:
        return default
    try:
        return int(ports_str.split("->")[0].split(":")[-1])
    except (ValueError, IndexError):
        return default

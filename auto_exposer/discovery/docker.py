import subprocess
from utils.logger import logger
from models.service import DiscoveredService

# Known services: container_name -> service config dict
KNOWN_SERVICES = {
    "npm": {"name": "Nginx Proxy Manager", "port": 81, "group": "Infrastructure", "icon": "nginx-proxy-manager"},
    "vaultwarden": {"name": "Vaultwarden", "port": 8080, "group": "Security", "icon": "vaultwarden"},
    "homepage": {"name": "Homepage", "port": 3000, "group": "Dashboard", "icon": "homepage"},
    "portainer": {"name": "Portainer", "port": 9000, "group": "Infrastructure", "icon": "portainer"},
    "syncthing": {"name": "Syncthing", "port": 8384, "group": "Sync & Backup", "icon": "syncthing"},
    "couchdb": {
        "name": "CouchDB", "port": 5984, "group": "Sync & Backup", "icon": "couchdb",
        "advanced_config": "location = / {\n    return 301 /_utils;\n}"
    },
    "immich_server": {"name": "Immich", "port": 2283, "group": "Media", "icon": "immich"},
    "jellyfin": {"name": "Jellyfin", "port": 8096, "group": "Media", "icon": "jellyfin"},
    "n8n": {"name": "n8n", "port": 5678, "group": "Automation", "icon": "n8n"},
    "pgadmin": {"name": "pgAdmin", "port": 80, "group": "Database", "icon": "pgadmin"},
    "evolution_api": {"name": "Evolution API", "port": 8080, "group": "Automation", "icon": "whatsapp"},
    "evolution-api": {"name": "Evolution API", "port": 8080, "group": "Automation", "icon": "whatsapp"},
    "evolution_manager": {"name": "Evolution Manager", "port": 80, "group": "Automation", "icon": "whatsapp"},
    "evolution-manager": {"name": "Evolution Manager", "port": 80, "group": "Automation", "icon": "whatsapp"},
    "cosync-frontend": {"name": "CoSync Workspace", "port": 5173, "group": "Sync & Backup", "icon": "si-obsidian"},
    "cosync-backend": {"name": "CoSync API", "port": 4000, "group": "Sync & Backup", "icon": "si-obsidian"},
    "nextcloud": {"name": "Nextcloud", "port": 8080, "group": "Cloud", "icon": "nextcloud"},
}

# Skip these (background/infrastructure containers not user-facing)
SKIP_SERVICES = {
    "watchtower", "portainer_agent", "portainer-agent", "docker-mcp",
    "duckduckgo-mcp", "proxmox-mcp", "postgres", "redis", "mysql",
    "mariadb", "mongodb", "rabbitmq", "influxdb", "cloudflared"
}


def discover_from_lxc(ctid, lxc_name, lxc_ip, base_domain):
    services = []
    try:
        cmd = [
            "/usr/sbin/pct", "exec", str(ctid), "--", "bash", "-c",
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

            if name in SKIP_SERVICES:
                continue

            # Parse labels
            labels = {}
            if labels_str:
                for item in labels_str.split(","):
                    if "=" in item:
                        k, v = item.split("=", 1)
                        labels[k] = v

            if labels.get("autoexposer.enable") == "false":
                continue

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
                    advanced_config=labels.get("autoexposer.advanced_config", ""),
                    lxc_name=lxc_name,
                    skip_cf=labels.get("autoexposer.skip_cf", "false").lower() == "true",
                    skip_npm=labels.get("autoexposer.skip_npm", "false").lower() == "true"
                ))
            # Known service auto-detection
            elif name in KNOWN_SERVICES:
                info = KNOWN_SERVICES[name]
                port = _parse_port(ports, info["port"])
                skip_cf_val = labels.get("autoexposer.skip_cf", "").lower()
                skip_cf = skip_cf_val == "true" if skip_cf_val else info.get("skip_cf", False)
                skip_npm = labels.get("autoexposer.skip_npm", "false").lower() == "true"
                services.append(DiscoveredService(
                    name=info["name"],
                    domain=f"{name}.{base_domain}",
                    ip=lxc_ip,
                    port=port,
                    group=info["group"],
                    icon=info["icon"],
                    advanced_config=info.get("advanced_config", ""),
                    lxc_name=lxc_name,
                    skip_cf=skip_cf,
                    skip_npm=skip_npm
                ))
            else:
                # Unknown container - still add with best-effort
                port = _parse_port(ports, 80)
                if port:
                    services.append(DiscoveredService(
                        name=name.replace("_", " ").replace("-", " ").title(),
                        domain=f"{name}.{base_domain}",
                        ip=lxc_ip,
                        port=port,
                        group="Other Services",
                        icon="docker",
                        lxc_name=lxc_name,
                        skip_cf=labels.get("autoexposer.skip_cf", "false").lower() == "true",
                        skip_npm=labels.get("autoexposer.skip_npm", "false").lower() == "true"
                    ))

    except subprocess.TimeoutExpired:
        logger.debug(f"Docker discovery timed out for LXC {lxc_name}")
    except Exception as e:
        logger.debug(f"Docker discovery failed for LXC {lxc_name}: {e}")
    return services


def _parse_port(ports_str, default=80):
    """Extract the first host port from Docker's port string."""
    if not ports_str or "->" not in ports_str:
        return default
    try:
        return int(ports_str.split("->")[0].split(":")[-1])
    except (ValueError, IndexError):
        return default

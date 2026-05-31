import subprocess
from utils.logger import logger
from models.service import DiscoveredService

# Known non-Docker services to scan for (port -> service info)
NON_DOCKER_SERVICES = {
    3000: ("AdGuard Home", "adguard", "DNS & Security", "adguard-home"),
    80: ("Web Server", "web", "Infrastructure", "nginx"),
    8080: ("Web App", "webapp", "Applications", "web"),
}


def discover_non_docker(ctid, lxc_name, lxc_ip, base_domain):
    """Discover services running directly on the LXC (not in Docker)."""
    services = []

    # First check if Docker is running - if so, skip non-docker discovery
    try:
        docker_check = subprocess.run(
            ["/usr/sbin/pct", "exec", str(ctid), "--", "bash", "-c", "command -v docker && docker ps -q | head -1"],
            capture_output=True, text=True, timeout=10
        )
        if docker_check.returncode == 0 and docker_check.stdout.strip():
            # Docker is running and has containers, skip non-docker scan
            return services
    except:
        pass

    # Scan for known listening ports using ss
    try:
        res = subprocess.run(
            ["/usr/sbin/pct", "exec", str(ctid), "--", "bash", "-c",
             "ss -tlnp 2>/dev/null | grep LISTEN | awk '{print $4}' | grep -oP '\\d+$' | sort -u"],
            capture_output=True, text=True, timeout=10
        )
        if res.returncode != 0:
            return services

        listening_ports = set()
        for line in res.stdout.splitlines():
            line = line.strip()
            if line.isdigit():
                listening_ports.add(int(line))

        # Check for AdGuard Home specifically (runs on port 3000 for setup, then port 80)
        if 3000 in listening_ports or 80 in listening_ports:
            # Check if AdGuard Home is installed
            ag_check = subprocess.run(
                ["/usr/sbin/pct", "exec", str(ctid), "--", "bash", "-c",
                 "test -f /opt/AdGuardHome/AdGuardHome && echo yes"],
                capture_output=True, text=True, timeout=5
            )
            if ag_check.returncode == 0 and "yes" in ag_check.stdout:
                # AdGuard runs on port 80 after initial setup, or 3000 during setup
                port = 80 if 80 in listening_ports else 3000
                services.append(DiscoveredService(
                    name="AdGuard Home",
                    domain=f"adguard.{base_domain}",
                    ip=lxc_ip,
                    port=port,
                    group="DNS & Security",
                    icon="adguard-home",
                    is_docker=False,
                    lxc_name=lxc_name
                ))
                return services

    except subprocess.TimeoutExpired:
        logger.debug(f"Non-Docker discovery timed out for LXC {lxc_name}")
    except Exception as e:
        logger.debug(f"Non-Docker discovery failed for LXC {lxc_name}: {e}")

    return services

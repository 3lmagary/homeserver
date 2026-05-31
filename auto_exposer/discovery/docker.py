import subprocess
from utils.logger import logger
from models.service import DiscoveredService

def discover_from_lxc(ctid, lxc_name, lxc_ip, base_domain):
    services = []
    try:
        # We look for containers and their exposed ports, formatting with labels
        cmd = ["pct", "exec", str(ctid), "--", "docker", "ps", "--format", "{{.Names}}|{{.Ports}}|{{.Labels}}"]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0: return services

        for line in res.stdout.splitlines():
            parts = line.split('|')
            if len(parts) < 3: continue
            name, ports, labels_str = parts[0], parts[1], parts[2]
            
            # Simple port parsing
            port = 80
            if "->" in ports:
                try:
                    port = int(ports.split("->")[0].split(":")[-1])
                except:
                    pass
            
            # Parse Labels
            labels = dict(item.split("=") for item in labels_str.split(",") if "=" in item)
            
            if labels.get("autoexposer.enable") == "true":
                services.append(DiscoveredService(
                    name=labels.get("autoexposer.name", name.capitalize()),
                    domain=f"{name}.{base_domain}",
                    ip=lxc_ip,
                    port=int(labels.get("autoexposer.port", port)),
                    group=labels.get("autoexposer.group", "Docker Services"),
                    icon=labels.get("autoexposer.icon", "docker"),
                    lxc_name=lxc_name
                ))
    except Exception as e:
        logger.debug(f"Docker discovery failed for LXC {lxc_name}")
    return services

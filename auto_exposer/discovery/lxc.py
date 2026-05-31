import subprocess
from utils.logger import logger

def get_lxcs():
    try:
        result = subprocess.run(["/usr/sbin/pct", "list"], capture_output=True, text=True)
        lines = result.stdout.splitlines()[1:]
        lxcs = []
        for line in lines:
            parts = line.split()
            if len(parts) >= 3 and parts[1] == "running":
                lxcs.append({"id": parts[0], "name": parts[2]})
        return lxcs
    except Exception as e:
        logger.warning(f"Could not run pct list: {e}")
        return []

def get_lxc_ip(ctid):
    try:
        res = subprocess.run(["/usr/sbin/pct", "exec", str(ctid), "--", "ip", "-4", "addr", "show", "eth0"], capture_output=True, text=True)
        for line in res.stdout.splitlines():
            if "inet " in line:
                return line.split()[1].split('/')[0]
    except:
        pass
    return None

import os
import subprocess
import typer
import yaml
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from utils.logger import logger
from db.state import StateManager
from providers.npm import NPMClient
from providers.cloudflare import CloudflareClient
from discovery.lxc import get_lxcs, get_lxc_ip
from discovery.docker import discover_from_lxc
from discovery.non_docker import discover_non_docker
from models.service import DiscoveredService

console = Console()
app = typer.Typer()


def get_proxmox_ip():
    """Detect the IP address of the Proxmox host."""
    try:
        # Check vmbr0 first as it's the standard PVE bridge
        res = subprocess.run(
            ["ip", "-4", "addr", "show", "dev", "vmbr0"],
            capture_output=True, text=True, timeout=5
        )
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if "inet " in line:
                    ip = line.strip().split()[1].split("/")[0]
                    return ip
        # Fallback to hostname -I
        res = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=5)
        if res.returncode == 0:
            ips = res.stdout.strip().split()
            if ips:
                return ips[0]
    except Exception as e:
        logger.error(f"Failed to detect Proxmox IP: {e}")
    return None


def get_core_services_ctid():
    """Find the LXC Container ID for the Core-Services container."""
    try:
        res = subprocess.run(["pct", "list"], capture_output=True, text=True, timeout=5)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if "Core-Services" in line:
                    return line.strip().split()[0]
    except Exception as e:
        logger.error(f"Failed to find Core-Services CTID: {e}")
    return None


def update_homepage_config(all_services, ctid):
    """Generate and write services.yaml configuration to Homepage LXC container."""
    if not ctid:
        logger.warning("Core-Services CTID not found, skipping Homepage config generation.")
        return False
    
    services_yaml_structure = []
    groups = {}
    
    for s in all_services:
        g_name = s.group or "Other Services"
        if g_name not in groups:
            groups[g_name] = []
        
        # Force HTTPS since we configure SSL wildcard cert
        href = f"https://{s.domain}"
        
        svc_entry = {
            s.name: {
                "icon": s.icon or "docker",
                "href": href,
                "description": s.description or f"{s.name} dashboard"
            }
        }
        groups[g_name].append(svc_entry)
        
    for g_name, svcs in groups.items():
        services_yaml_structure.append({g_name: svcs})
        
    yaml_content = yaml.dump(services_yaml_structure, sort_keys=False, default_flow_style=False)
    
    try:
        # Ensure config directory exists in the LXC
        subprocess.run(["pct", "exec", str(ctid), "--", "mkdir", "-p", "/opt/core/homepage"], check=True)
        
        # Write services.yaml inside LXC
        cmd = ["pct", "exec", str(ctid), "--", "bash", "-c", "cat > /opt/core/homepage/services.yaml"]
        res = subprocess.run(cmd, input=yaml_content, capture_output=True, text=True, timeout=10)
        if res.returncode == 0:
            logger.info("Successfully updated Homepage services.yaml in LXC")
            
            # Restart Homepage container to force reload configs cleanly
            subprocess.run([
                "pct", "exec", str(ctid), "--", "bash", "-c",
                "cd /opt/core && docker compose restart homepage"
            ], capture_output=True, timeout=20)
            logger.info("Restarted Homepage container in LXC")
            return True
        else:
            logger.error(f"Failed to write services.yaml to LXC: {res.stderr}")
    except Exception as e:
        logger.error(f"Error updating Homepage config: {e}")
        
    return False


@app.command()
def init():
    console.print("[green]Initializing AutoExposer...[/green]")
    pass


@app.command()
def clean(base_domain: str = None):
    """Delete all configured NPM hosts and Cloudflare DNS records for the domain."""
    if not base_domain:
        base_domain = os.getenv("CF_DOMAIN", "example.com")

    console.print(Panel.fit(
        f"[bold red]AutoExposer Cleanup[/bold red]\n"
        f"Domain: [cyan]{base_domain}[/cyan]",
        border_style="red"
    ))

    # ── Connect to NPM ──
    npm_url = os.getenv("NPM_URL")
    npm_email = os.getenv("NPM_EMAIL")
    npm_password = os.getenv("NPM_PASSWORD")
    npm = None
    if npm_url and npm_email and npm_password:
        with console.status("[bold red]Connecting to Nginx Proxy Manager..."):
            npm = NPMClient(npm_url, npm_email, npm_password)
            if not npm.token:
                console.print("[red]Failed to connect to NPM. Check credentials.[/red]")
                npm = None

    # ── Connect to Cloudflare ──
    cf_token = os.getenv("CF_API_TOKEN")
    cf = None
    if cf_token:
        with console.status("[bold red]Connecting to Cloudflare..."):
            cf = CloudflareClient(cf_token, base_domain)
            if not cf.zone_id:
                console.print("[red]Failed to connect to Cloudflare. Check API token.[/red]")
                cf = None

    if npm:
        with console.status(f"[bold red]Deleting NPM proxy hosts for {base_domain}..."):
            deleted_hosts = npm.cleanup_hosts(base_domain)
            console.print(f"[green]✓ Cleaned up {deleted_hosts} NPM proxy hosts.[/green]")

    if cf:
        with console.status(f"[bold red]Deleting Cloudflare DNS records for {base_domain}..."):
            records = cf.get_dns_records()
            deleted_dns = 0
            for r in records:
                name = r.get("name", "")
                if name.endswith(base_domain) or name == base_domain:
                    if cf.delete_dns_record(r["id"]):
                        deleted_dns += 1
            console.print(f"[green]✓ Cleaned up {deleted_dns} Cloudflare A records.[/green]")


@app.command()
def sync(dry_run: bool = False, base_domain: str = None, run_cleanup: bool = False):
    """Discover services, check existing configurations, configure NPM proxy hosts and Cloudflare DNS, and update Homepage."""
    if not base_domain:
        base_domain = os.getenv("CF_DOMAIN", "example.com")

    console.print(Panel.fit(
        f"[bold blue]AutoExposer Sync[/bold blue]\n"
        f"Domain: [cyan]{base_domain}[/cyan] | Dry Run: [yellow]{dry_run}[/yellow] | Cleanup: [yellow]{run_cleanup}[/yellow]",
        border_style="blue"
    ))

    # ── Step 1: Discover all services ──
    lxcs = get_lxcs()
    all_services = []

    with console.status("[bold green]Discovering services across all LXCs..."):
        for lxc in lxcs:
            ip = get_lxc_ip(lxc['id'])
            if ip:
                # Docker services
                docker_svcs = discover_from_lxc(lxc['id'], lxc['name'], ip, base_domain)
                all_services.extend(docker_svcs)
                # Non-Docker services (AdGuard, etc.)
                non_docker_svcs = discover_non_docker(lxc['id'], lxc['name'], ip, base_domain)
                all_services.extend(non_docker_svcs)

    # ── Step 2: Auto-detect and add Proxmox host itself as a service ──
    proxmox_ip = get_proxmox_ip()
    if proxmox_ip:
        all_services.append(DiscoveredService(
            name="Proxmox VE",
            domain=f"proxmox.{base_domain}",
            ip=proxmox_ip,
            port=8006,
            group="Infrastructure",
            icon="proxmox",
            forward_scheme="https",
            is_docker=False,
            lxc_name="Proxmox Host",
            description="Proxmox VE Management Web Interface"
        ))
        console.print(f"[green]✓ Detected Proxmox Host IP: {proxmox_ip}[/green]")

    if not all_services:
        console.print("[red]No services discovered. Make sure your LXCs are running.[/red]")
        return

    # Display discovered services
    table = Table(title="Discovered Services", border_style="blue")
    table.add_column("#", style="dim", width=3)
    table.add_column("Service", style="cyan", no_wrap=True)
    table.add_column("Domain", style="magenta")
    table.add_column("Target", style="green")
    table.add_column("LXC", style="yellow")
    table.add_column("Type", style="dim")

    for i, s in enumerate(all_services, 1):
        svc_type = "Docker" if s.is_docker else "Native"
        table.add_row(str(i), s.name, s.domain, f"{s.ip}:{s.port}", s.lxc_name or "-", svc_type)

    console.print(table)

    if dry_run:
        console.print("[yellow]Dry run mode - no changes will be made.[/yellow]")
        return

    # ── Step 3: Connect to NPM ──
    npm_url = os.getenv("NPM_URL")
    npm_email = os.getenv("NPM_EMAIL")
    npm_password = os.getenv("NPM_PASSWORD")

    npm = None
    if npm_url and npm_email and npm_password:
        with console.status("[bold green]Connecting to Nginx Proxy Manager..."):
            npm = NPMClient(npm_url, npm_email, npm_password)
            if not npm.token:
                console.print("[red]Failed to connect to NPM. Check credentials.[/red]")
                npm = None

    # ── Step 4: Connect to Cloudflare ──
    cf_token = os.getenv("CF_API_TOKEN")
    cf = None
    if cf_token:
        with console.status("[bold green]Connecting to Cloudflare..."):
            cf = CloudflareClient(cf_token, base_domain)
            if not cf.zone_id:
                console.print("[red]Failed to connect to Cloudflare. Check API token.[/red]")
                cf = None

    # ── Step 5: Optional Cleanup (Only run if explicitly passed run_cleanup=True) ──
    if run_cleanup:
        if npm:
            with console.status(f"[bold red]Cleaning up old NPM hosts for {base_domain}..."):
                deleted = npm.cleanup_hosts(base_domain)
                console.print(f"[green]✓ Cleaned up {deleted} old NPM hosts.[/green]")
        if cf:
            with console.status(f"[bold red]Cleaning up old Cloudflare A records for {base_domain}..."):
                records = cf.get_dns_records()
                deleted_dns = 0
                for r in records:
                    name = r.get("name", "")
                    if name.endswith(base_domain) or name == base_domain:
                        if cf.delete_dns_record(r["id"]):
                            deleted_dns += 1
                console.print(f"[green]✓ Cleaned up {deleted_dns} old Cloudflare A records.[/green]")

    # ── Step 6: Get existing NPM hosts to avoid duplicates ──
    existing_npm_hosts = {}
    if npm:
        with console.status("[bold green]Fetching existing NPM proxy hosts..."):
            existing_hosts = npm.get_hosts()
            for host in existing_hosts:
                for domain in host.get("domain_names", []):
                    existing_npm_hosts[domain] = host.get("id")

    # ── Step 7: Determine NPM Internal IP for DNS routing ──
    npm_ip = None
    for s in all_services:
        if s.name == "Nginx Proxy Manager" or s.domain.startswith("npm."):
            npm_ip = s.ip
            break
    if not npm_ip:
        for s in all_services:
            if s.port == 81:
                npm_ip = s.ip
                break
    if not npm_ip:
        core_ctid = get_core_services_ctid()
        if core_ctid:
            npm_ip = get_lxc_ip(core_ctid)

    if not npm_ip:
        console.print("[red]Could not determine NPM IP. Cloudflare DNS will be skipped.[/red]")
        cf = None
    else:
        console.print(f"[green]✓ Using NPM IP ({npm_ip}) for local DNS routing.[/green]")

    # ── Step 8: Ensure Wildcard SSL Certificate via Let's Encrypt DNS Challenge ──
    certificate_id = 0
    if npm and cf_token:
        with console.status(f"[bold green]Ensuring wildcard SSL certificate for *.{base_domain}..."):
            cert = npm.create_letsencrypt_cert(base_domain, npm_email, cf_token)
            if cert:
                certificate_id = cert.get("id", 0)
                console.print(f"[green]✓ Wildcard SSL certificate active (ID: {certificate_id})[/green]")
            else:
                console.print("[yellow]⚠ Failed to ensure wildcard SSL certificate. Proxy hosts will be created without SSL.[/yellow]")

    # ── Step 9: Create NPM Proxy Hosts + Cloudflare DNS ──
    results_table = Table(title="Sync Results", border_style="green")
    results_table.add_column("Service", style="cyan")
    results_table.add_column("Domain", style="magenta")
    results_table.add_column("NPM Proxy", style="green")
    results_table.add_column("Cloudflare DNS", style="blue")

    state = StateManager(db_path=os.path.join(os.path.dirname(__file__), "..", "state.sqlite"))

    for s in all_services:
        npm_status = "-"
        cf_status = "-"

        # Create NPM Proxy Host only if it doesn't already exist
        if npm:
            if s.domain in existing_npm_hosts:
                npm_status = "✓ Exists"
            else:
                result = npm.create_host(
                    domain=s.domain,
                    ip=s.ip,
                    port=s.port,
                    certificate_id=certificate_id,
                    ssl_forced=(certificate_id > 0),
                    advanced_config=s.advanced_config,
                    forward_scheme=s.forward_scheme
                )
                if result:
                    npm_status = "✓ Created"
                    npm_id = result.get("id", 0)
                    state.save(s.domain, s.ip, s.port, npm_id, {"name": s.name, "group": s.group})
                else:
                    npm_status = "✗ Failed"

        # Create Cloudflare DNS Record (pointing to local NPM IP)
        if cf and npm_ip:
            subdomain = s.domain.replace(f".{base_domain}", "")
            result = cf.create_dns_record(subdomain, npm_ip, proxied=False)
            if result:
                cf_status = "✓ Done (Local IP)"
            else:
                cf_status = "✗ Failed"

        results_table.add_row(s.name, s.domain, npm_status, cf_status)

    console.print(results_table)

    # ── Step 10: Generate and update Homepage configuration ──
    core_ctid = get_core_services_ctid()
    if core_ctid:
        with console.status("[bold green]Updating Homepage Dashboard configuration..."):
            if update_homepage_config(all_services, core_ctid):
                console.print("[green]✓ Homepage dashboard configuration updated and reloaded.[/green]")
            else:
                console.print("[yellow]⚠ Failed to update Homepage configuration.[/yellow]")
    else:
        console.print("[yellow]⚠ Core-Services LXC not found. Skipping Homepage dashboard update.[/yellow]")

    console.print(Panel.fit(
        "[bold green]✓ Sync Complete![/bold green]\n"
        "All discovered services have been configured successfully.",
        border_style="green"
    ))

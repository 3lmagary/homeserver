import os
import typer
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

console = Console()
app = typer.Typer()


@app.command()
def init():
    console.print("[green]Initializing AutoExposer...[/green]")
    pass


@app.command()
def sync(dry_run: bool = False, base_domain: str = None):
    if not base_domain:
        base_domain = os.getenv("CF_DOMAIN", "example.com")

    console.print(Panel.fit(
        f"[bold blue]AutoExposer Sync[/bold blue]\n"
        f"Domain: [cyan]{base_domain}[/cyan] | Dry Run: [yellow]{dry_run}[/yellow]",
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

    # ── Step 2: Connect to NPM ──
    npm_url = os.getenv("NPM_URL")
    npm_email = os.getenv("NPM_EMAIL")
    npm_password = os.getenv("NPM_PASSWORD")

    npm = None
    if npm_url and npm_email and npm_password:
        with console.status("[bold green]Connecting to Nginx Proxy Manager..."):
            npm = NPMClient(npm_url, npm_email, npm_password)
            if not npm.token:
                console.print("[red]Failed to connect to NPM. Check your credentials.[/red]")
                npm = None

    # ── Step 3: Connect to Cloudflare ──
    cf_token = os.getenv("CF_API_TOKEN")
    cf = None
    if cf_token:
        with console.status("[bold green]Connecting to Cloudflare..."):
            cf = CloudflareClient(cf_token, base_domain)
            if not cf.zone_id:
                console.print("[red]Failed to connect to Cloudflare. Check your API token.[/red]")
                cf = None

    # ── Step 4: Get your public IP for Cloudflare DNS ──
    public_ip = None
    if cf:
        try:
            import requests
            public_ip = requests.get("https://api.ipify.org", timeout=5).text.strip()
            console.print(f"[green]✓ Public IP detected: {public_ip}[/green]")
        except:
            console.print("[yellow]⚠ Could not detect public IP. DNS records will be skipped.[/yellow]")
            cf = None

    # ── Step 5: Get existing NPM hosts to avoid duplicates ──
    existing_npm_domains = set()
    if npm:
        existing_hosts = npm.get_hosts()
        for host in existing_hosts:
            for domain in host.get("domain_names", []):
                existing_npm_domains.add(domain)

    # ── Step 6: Create NPM Proxy Hosts + Cloudflare DNS ──
    results_table = Table(title="Sync Results", border_style="green")
    results_table.add_column("Service", style="cyan")
    results_table.add_column("Domain", style="magenta")
    results_table.add_column("NPM", style="green")
    results_table.add_column("Cloudflare", style="blue")

    state = StateManager(db_path=os.path.join(os.path.dirname(__file__), "..", "state.sqlite"))

    for s in all_services:
        npm_status = "-"
        cf_status = "-"

        # Create NPM Proxy Host
        if npm:
            if s.domain in existing_npm_domains:
                npm_status = "✓ Exists"
            else:
                result = npm.create_host(s.domain, s.ip, s.port)
                if result:
                    npm_status = "✓ Created"
                    npm_id = result.get("id", 0)
                    state.save(s.domain, s.ip, s.port, npm_id, {"name": s.name, "group": s.group})
                else:
                    npm_status = "✗ Failed"

        # Create Cloudflare DNS Record
        if cf and public_ip:
            subdomain = s.domain.replace(f".{base_domain}", "")
            result = cf.create_dns_record(subdomain, public_ip, proxied=True)
            if result:
                cf_status = "✓ Done"
            else:
                cf_status = "✗ Failed"

        results_table.add_row(s.name, s.domain, npm_status, cf_status)

    console.print(results_table)
    console.print(Panel.fit(
        "[bold green]✓ Sync Complete![/bold green]\n"
        "All discovered services have been configured.",
        border_style="green"
    ))

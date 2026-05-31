import typer
from rich.console import Console
from rich.table import Table
from utils.logger import logger
from db.state import StateManager
from providers.npm import NPMClient
from discovery.lxc import get_lxcs, get_lxc_ip
from discovery.docker import discover_from_lxc

console = Console()
app = typer.Typer()

@app.command()
def init():
    console.print("[green]Initializing AutoExposer...[/green]")
    # Create necessary files
    pass

@app.command()
def sync(dry_run: bool = False, base_domain: str = "example.com"):
    console.print(f"[bold blue]Starting AutoExposer Sync (Dry Run: {dry_run})[/bold blue]")
    lxcs = get_lxcs()
    all_services = []
    
    with console.status("[bold green]Discovering services..."):
        for lxc in lxcs:
            ip = get_lxc_ip(lxc['id'])
            if ip:
                svcs = discover_from_lxc(lxc['id'], lxc['name'], ip, base_domain)
                all_services.extend(svcs)
    
    table = Table(title="Discovered Services")
    table.add_column("Service", style="cyan")
    table.add_column("Domain", style="magenta")
    table.add_column("Target", style="green")
    
    for s in all_services:
        table.add_row(s.name, s.domain, f"{s.ip}:{s.port}")
    
    console.print(table)

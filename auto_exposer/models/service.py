from pydantic import BaseModel, Field
from typing import Optional

class DiscoveredService(BaseModel):
    name: str
    domain: str
    ip: str
    port: int
    group: str = "Uncategorized"
    icon: str = "docker"
    description: str = ""
    is_docker: bool = True
    lxc_name: Optional[str] = None
    advanced_config: str = ""
    forward_scheme: str = "http"

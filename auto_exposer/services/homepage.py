import yaml
import os

def generate_yaml(services, filepath="/opt/core/homepage/services.yaml"):
    groups = {}
    for s in services:
        if s.group not in groups:
            groups[s.group] = []
        groups[s.group].append({
            s.name: {
                "icon": f"{s.icon}.png",
                "href": f"http://{s.domain}",
                "description": s.description
            }
        })
    
    yaml_data = [{k: v} for k, v in groups.items()]
    
    with open("services_generated.yaml", "w") as f:
        yaml.safe_dump(yaml_data, f, default_flow_style=False, sort_keys=False)
    
    return yaml_data

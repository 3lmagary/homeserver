import requests
from utils.logger import logger


class CloudflareClient:
    def __init__(self, api_token, domain):
        self.api_token = api_token
        self.domain = domain
        self.base_url = "https://api.cloudflare.com/client/v4"
        self.headers = {
            "Authorization": f"Bearer {api_token}",
            "Content-Type": "application/json"
        }
        self.zone_id = self._get_zone_id()

    def _get_zone_id(self):
        """Get the Cloudflare Zone ID for the domain."""
        try:
            res = requests.get(
                f"{self.base_url}/zones",
                headers=self.headers,
                params={"name": self.domain}
            )
            data = res.json()
            if data.get("success") and data.get("result"):
                zone_id = data["result"][0]["id"]
                logger.info(f"Found Cloudflare Zone ID for {self.domain}")
                return zone_id
            else:
                logger.error(f"Could not find Cloudflare zone for {self.domain}")
                return None
        except Exception as e:
            logger.error(f"Cloudflare API error: {e}")
            return None

    def get_dns_records(self):
        """Get all existing DNS records for the zone."""
        if not self.zone_id:
            return []
        try:
            records = []
            page = 1
            while True:
                res = requests.get(
                    f"{self.base_url}/zones/{self.zone_id}/dns_records",
                    headers=self.headers,
                    params={"type": "A", "per_page": 100, "page": page}
                )
                data = res.json()
                if data.get("success"):
                    records.extend(data.get("result", []))
                    total_pages = data.get("result_info", {}).get("total_pages", 1)
                    if page >= total_pages:
                        break
                    page += 1
                else:
                    break
            return records
        except Exception as e:
            logger.error(f"Failed to get DNS records: {e}")
            return []

    def create_dns_record(self, subdomain, ip, proxied=True):
        """Create an A record pointing the subdomain to the given IP."""
        if not self.zone_id:
            return None
        full_domain = f"{subdomain}.{self.domain}" if subdomain != self.domain else self.domain
        try:
            # Check if record already exists
            existing = self._find_record(full_domain)
            if existing:
                # Update if IP changed
                if existing["content"] != ip:
                    return self._update_record(existing["id"], full_domain, ip, proxied)
                logger.info(f"DNS record for {full_domain} already exists with correct IP")
                return existing
            
            res = requests.post(
                f"{self.base_url}/zones/{self.zone_id}/dns_records",
                headers=self.headers,
                json={
                    "type": "A",
                    "name": full_domain,
                    "content": ip,
                    "ttl": 1,  # Auto
                    "proxied": proxied
                }
            )
            data = res.json()
            if data.get("success"):
                logger.info(f"Created DNS record: {full_domain} -> {ip}")
                return data["result"]
            else:
                logger.error(f"Failed to create DNS record for {full_domain}: {data.get('errors')}")
                return None
        except Exception as e:
            logger.error(f"Cloudflare API error creating record: {e}")
            return None

    def _find_record(self, full_domain):
        """Find an existing DNS record by full domain name."""
        if not self.zone_id:
            return None
        try:
            res = requests.get(
                f"{self.base_url}/zones/{self.zone_id}/dns_records",
                headers=self.headers,
                params={"type": "A", "name": full_domain}
            )
            data = res.json()
            if data.get("success") and data.get("result"):
                return data["result"][0]
        except:
            pass
        return None

    def _update_record(self, record_id, full_domain, ip, proxied=True):
        """Update an existing DNS record."""
        try:
            res = requests.put(
                f"{self.base_url}/zones/{self.zone_id}/dns_records/{record_id}",
                headers=self.headers,
                json={
                    "type": "A",
                    "name": full_domain,
                    "content": ip,
                    "ttl": 1,
                    "proxied": proxied
                }
            )
            data = res.json()
            if data.get("success"):
                logger.info(f"Updated DNS record: {full_domain} -> {ip}")
                return data["result"]
        except Exception as e:
            logger.error(f"Failed to update DNS record: {e}")
        return None

    def delete_dns_record(self, record_id):
        """Delete a DNS record by ID."""
        if not self.zone_id:
            return False
        try:
            res = requests.delete(
                f"{self.base_url}/zones/{self.zone_id}/dns_records/{record_id}",
                headers=self.headers,
                timeout=10
            )
            data = res.json()
            if data.get("success"):
                logger.info(f"Deleted DNS record ID: {record_id}")
                return True
            else:
                logger.error(f"Failed to delete DNS record ID {record_id}: {data.get('errors')}")
                return False
        except Exception as e:
            logger.error(f"Cloudflare API error deleting record: {e}")
            return False

import requests
import time
from utils.logger import logger


class NPMClient:
    def __init__(self, url, email, password):
        self.url = url.rstrip('/')
        self.session = requests.Session()
        self.token = None
        self._login(email, password)

    def _login(self, email, password):
        try:
            res = self.session.post(f"{self.url}/api/tokens",
                                    json={"identity": email, "secret": password}, timeout=10)
            if res.status_code == 200:
                self.token = res.json().get('token')
                self.session.headers.update({"Authorization": f"Bearer {self.token}"})
                logger.info("Successfully logged into NPM API")
            else:
                logger.error(f"Failed to login to NPM: {res.status_code}")
        except Exception as e:
            logger.error(f"NPM connection error: {e}")

    def get_hosts(self):
        if not self.token:
            return []
        res = self.session.get(f"{self.url}/api/nginx/proxy-hosts", timeout=10)
        return res.json() if res.status_code == 200 else []

    def delete_host(self, host_id):
        if not self.token:
            return False
        res = self.session.delete(f"{self.url}/api/nginx/proxy-hosts/{host_id}", timeout=10)
        return res.status_code in [200, 204]

    def cleanup_hosts(self, base_domain):
        """Delete all proxy hosts whose domains end with base_domain."""
        hosts = self.get_hosts()
        deleted = 0
        for host in hosts:
            domains = host.get("domain_names", [])
            for d in domains:
                if d.endswith(base_domain):
                    if self.delete_host(host["id"]):
                        deleted += 1
                        logger.info(f"Deleted NPM proxy host: {d}")
                    break
        return deleted

    def get_certificates(self):
        if not self.token:
            return []
        res = self.session.get(f"{self.url}/api/nginx/certificates", timeout=10)
        return res.json() if res.status_code == 200 else []

    def find_wildcard_cert(self, domain):
        """Find an existing wildcard cert for the domain."""
        certs = self.get_certificates()
        for cert in certs:
            cert_domains = cert.get("domain_names", [])
            if f"*.{domain}" in cert_domains:
                # Check if it's actually provisioned (has expires_on)
                if cert.get("expires_on"):
                    return cert
        return None

    def create_letsencrypt_cert(self, domain, email, cf_token):
        """Create a wildcard Let's Encrypt cert using Cloudflare DNS challenge."""
        if not self.token:
            return None

        # Check if already exists
        existing = self.find_wildcard_cert(domain)
        if existing:
            logger.info(f"Wildcard cert for *.{domain} already exists (ID: {existing['id']})")
            return existing

        payload = {
            "nice_name": f"Wildcard {domain}",
            "domain_names": [f"*.{domain}", domain],
            "meta": {
                "letsencrypt_email": email,
                "letsencrypt_agree": True,
                "dns_challenge": True,
                "dns_provider": "cloudflare",
                "dns_provider_credentials": f"dns_cloudflare_api_token = {cf_token}",
                "propagation_seconds": 30
            },
            "provider": "letsencrypt"
        }

        try:
            res = self.session.post(f"{self.url}/api/nginx/certificates",
                                    json=payload, timeout=180)
            if res.status_code in [200, 201]:
                cert = res.json()
                logger.info(f"Wildcard certificate created for *.{domain} (ID: {cert.get('id')})")
                return cert
            else:
                logger.error(f"Certificate creation failed: {res.text[:200]}")
                return None
        except requests.exceptions.Timeout:
            logger.error("Certificate creation timed out (this can take up to 3 minutes)")
            # Check if it was created despite timeout
            existing = self.find_wildcard_cert(domain)
            if existing:
                return existing
            return None
        except Exception as e:
            logger.error(f"Certificate creation error: {e}")
            return None

    def create_host(self, domain, ip, port, certificate_id=0, ssl_forced=False,
                    advanced_config="", forward_scheme="http"):
        payload = {
            "domain_names": [domain],
            "forward_scheme": forward_scheme,
            "forward_host": ip,
            "forward_port": port,
            "access_list_id": 0,
            "certificate_id": certificate_id,
            "ssl_forced": ssl_forced,
            "meta": {"letsencrypt_agree": False, "dns_challenge": False},
            "advanced_config": advanced_config,
            "block_exploits": True,
            "allow_websocket_upgrade": True,
            "http2_support": True
        }
        try:
            res = self.session.post(f"{self.url}/api/nginx/proxy-hosts",
                                    json=payload, timeout=15)
            if res.status_code in [200, 201]:
                return res.json()
            else:
                logger.error(f"Failed to create host {domain}: {res.text[:200]}")
                return None
        except Exception as e:
            logger.error(f"Error creating host {domain}: {e}")
            return None

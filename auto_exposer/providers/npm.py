import requests
from utils.logger import logger

class NPMClient:
    def __init__(self, url, email, password):
        self.url = url
        self.session = requests.Session()
        self.token = None
        self._login(email, password)

    def _login(self, email, password):
        res = self.session.post(f"{self.url}/api/tokens", json={"identity": email, "secret": password})
        if res.status_code == 200:
            self.token = res.json().get('token')
            self.session.headers.update({"Authorization": f"Bearer {self.token}"})
            logger.info("Successfully logged into NPM API")
        else:
            logger.error("Failed to login to NPM")

    def get_hosts(self):
        if not self.token: return []
        res = self.session.get(f"{self.url}/api/nginx/proxy-hosts")
        return res.json() if res.status_code == 200 else []

    def create_host(self, domain, ip, port):
        payload = {
            "domain_names": [domain],
            "forward_scheme": "http",
            "forward_host": ip,
            "forward_port": port,
            "access_list_id": 0,
            "certificate_id": 0,
            "meta": {"letsencrypt_agree": False, "dns_challenge": False}
        }
        res = self.session.post(f"{self.url}/api/nginx/proxy-hosts", json=payload)
        return res.json() if res.status_code in [200, 201] else None

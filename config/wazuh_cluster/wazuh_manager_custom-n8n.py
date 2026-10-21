#!/usr/bin/env python3
import json
import sys
import urllib.request
import urllib.error

# Wazuh passes:
# sys.argv[1] = alert file path
# sys.argv[2] = api_key (optional)
# sys.argv[3] = hook_url (optional)
alert_path = sys.argv[1] if len(sys.argv) > 1 else None
api_key = sys.argv[2] if len(sys.argv) > 2 else ""
hook_url = sys.argv[3] if len(sys.argv) > 3 else ""

if not alert_path or not hook_url:
    sys.exit(1)

with open(alert_path, "r", encoding="utf-8") as f:
    alert_json = json.load(f)

payload = {
    "source": "wazuh-integrator",
    "alert": alert_json
}

data = json.dumps(payload).encode("utf-8")

headers = {
    "Content-Type": "application/json"
}

if api_key:
    headers["X-API-Key"] = api_key

req = urllib.request.Request(
    hook_url,
    data=data,
    headers=headers,
    method="POST"
)

try:
    with urllib.request.urlopen(req, timeout=10) as response:
        # Read response so the request fully completes
        response.read()
except urllib.error.HTTPError as e:
    print(f"HTTPError: {e.code} {e.reason}")
    sys.exit(1)
except urllib.error.URLError as e:
    print(f"URLError: {e.reason}")
    sys.exit(1)
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)

sys.exit(0)
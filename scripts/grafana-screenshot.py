"""Скриншот дашборда sensor-gateway из Grafana (headless Chrome через Playwright).

python scripts/grafana-screenshot.py [URL] [OUT]
URL по умолчанию http://127.0.0.1:3000 (kubectl -n monitoring port-forward svc/mon-grafana 3000:80).
Пароль: GRAFANA_PASSWORD или Secret grafana-admin (kubectl).
"""
import base64
import os
import subprocess
import sys

from playwright.sync_api import sync_playwright

url = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:3000"
out = sys.argv[2] if len(sys.argv) > 2 else "docs/img/grafana-sensor-gateway.png"
user = os.environ.get("GRAFANA_USER", "admin")
password = os.environ.get("GRAFANA_PASSWORD") or base64.b64decode(subprocess.run(
    ["kubectl", "-n", "monitoring", "get", "secret", "grafana-admin", "-o", "jsonpath={.data.admin-password}"],
    capture_output=True, text=True, check=True).stdout).decode()

with sync_playwright() as p:
    browser = p.chromium.launch(channel=os.environ.get("PW_CHANNEL", "chrome"), headless=True)
    page = browser.new_page(viewport={"width": 1600, "height": 900})
    page.goto(f"{url}/login")
    page.fill("input[name=user]", user)
    page.fill("input[name=password]", password)
    page.click("button[type=submit]")
    page.wait_for_load_state("networkidle")
    page.goto(f"{url}/d/sensor-gateway/sensor-gateway?orgId=1&from=now-15m&to=now&kiosk")
    page.wait_for_load_state("networkidle")
    page.wait_for_timeout(5000)
    page.screenshot(path=out, full_page=True)
    browser.close()
print(out)

"""Tests for the validator and the repair loop without a real model (a fake OpenAI-compatible server)."""
import http.server
import json
import os
import subprocess
import sys
import threading

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
os.environ["LLM_NO_DOCKER"] = "1"
sys.path.insert(0, HERE)
import llm_gen  # noqa: E402

REPO_RULE = open(os.path.join(ROOT, "deploy", "monitoring", "prometheusrule.yaml"), encoding="utf-8").read()
GOOD = """apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: sensor-gateway
  namespace: monitoring
  labels:
    release: mon
spec:
  groups:
    - name: g
      rules:
        - alert: SensorGatewayDown
          expr: sum(up{namespace="sensor", service=~".*-api"}) == 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "down"
            description: "no targets"
        - alert: SensorGatewaySlowProbe
          expr: service_probe_latency_seconds > 0.5
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "slow"
            description: "slow probe"
"""


def test_repo_rule_is_valid():
    assert llm_gen.validate_rule_text(REPO_RULE) == []
    assert llm_gen.validate_rule_text(GOOD) == []


@pytest.mark.parametrize("broken,needle", [
    (GOOD.replace("release: mon", "release: other"), "release"),
    (GOOD.replace("severity: critical", "severity: page"), "severity"),
    (GOOD.replace("alert: SensorGatewayDown", "alert: sensor gateway down"), "CamelCase"),
    (GOOD.replace("for: 1m", "for: one minute"), "duration"),
    (GOOD.replace("name: sensor-gateway\n", "name: Sensor_Gateway\n", 1), "DNS-1123"),
    ("kind: [unclosed", "yaml"),
    (GOOD.replace("expr: service_probe_latency_seconds > 0.5", "expr: rate(service_probe_latency_seconds[5m]) > 0.5"), "gauge"),
    (GOOD.replace('service=~".*-api"', 'service=".*-api"'), "=~"),
])
def test_broken_rules_rejected(broken, needle):
    errs = llm_gen.validate_rule_text(broken)
    assert any(needle in e for e in errs), errs


def test_strip_fences():
    assert llm_gen.strip_fences("```yaml\na: 1\n```\ntext") == "a: 1\n"
    assert llm_gen.strip_fences("```yaml\na: 1\n") == "a: 1\n"


def test_generate_with_repair_against_fake_server(tmp_path):
    answers = [GOOD.replace("severity: critical", "severity: page"), GOOD]
    seen = []

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            seen.append(body)
            out = json.dumps({"choices": [{"message": {"content": answers[len(seen) - 1]}}], "usage": {}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    env = dict(os.environ, LLM_URL=f"http://127.0.0.1:{srv.server_port}", LLM_LOG=str(tmp_path / "runs.jsonl"))
    p = subprocess.run([sys.executable, os.path.join(HERE, "llm_gen.py"), "rule", "test alert",
                        "--out", str(tmp_path / "r.yaml")], env=env, capture_output=True, text=True)
    srv.shutdown()
    assert p.returncode == 0, p.stderr
    assert len(seen) == 2 and seen[0]["temperature"] == 0 and seen[0]["seed"] == 42
    assert "severity" in seen[1]["messages"][-1]["content"]
    run = json.loads((tmp_path / "runs.jsonl").read_text())
    assert run["valid"] and run["attempts"] == 2 and run["prompt_file"].startswith("llm/prompts/")


def test_cyrillic_share():
    assert llm_gen.cyrillic_share("- Что упало: smoke `login` вернула HTTP 401") > 0.5
    assert llm_gen.cyrillic_share("- Check failed: smoke login returned 401") < 0.1

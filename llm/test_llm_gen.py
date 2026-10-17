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
os.environ["LLM_SKIP_PROMTOOL"] = "1"
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


def test_promtool_missing_is_error(monkeypatch):
    monkeypatch.delenv("LLM_SKIP_PROMTOOL", raising=False)
    monkeypatch.setattr(llm_gen.shutil, "which", lambda name: None)
    doc = {"spec": {"groups": [{"name": "g", "rules": [{"alert": "A", "expr": "up == 0"}]}]}}
    errs = llm_gen.promtool_check(doc)
    assert errs and "promtool" in errs[0]


def _with_expr(expr):
    return GOOD.replace("expr: service_probe_latency_seconds > 0.5", "expr: " + expr)


def test_whitelist_rejects_unknown_metric_label_and_histogram_on_counter():
    # status is a real label. histogram_quantile still needs a *_bucket series.
    bad = _with_expr('histogram_quantile(0.95, sum(rate(http_requests_total{status=~"5.."}[5m])))')
    errs = llm_gen.validate_rule_text(bad)
    assert not any("нет метки status" in e for e in errs), errs
    assert any("histogram_quantile" in e and "http_requests_total" in e for e in errs), errs
    assert not any("неизвестная метрика http_requests_total" in e for e in errs), errs

    unknown_label = _with_expr('rate(http_requests_total{foo="1"}[5m])')
    label_errs = llm_gen.validate_rule_text(unknown_label)
    assert any("нет метки foo" in e and "http_requests_total" in e for e in label_errs), label_errs

    mem = _with_expr("process_resident_memory_bytes > 400000000")
    mem_errs = llm_gen.validate_rule_text(mem)
    assert any("неизвестная метрика process_resident_memory_bytes" in e for e in mem_errs), mem_errs


def test_whitelist_allows_nginx_5xx_and_http_duration_quantile():
    nginx = _with_expr(
        '(sum(rate(nginx_ingress_controller_requests{exported_namespace="sensor",status=~"5.."}[5m]))'
        ' or vector(0)) / sum(rate(nginx_ingress_controller_requests{exported_namespace="sensor"}[5m])) > 0.05'
    )
    assert llm_gen.validate_rule_text(nginx) == []

    latency = _with_expr(
        'histogram_quantile(0.95, sum by (le, service) (rate(http_request_duration_seconds_bucket{namespace="sensor",method="GET",path="/ready",status="200"}[5m]))) > 0.5'
    )
    assert llm_gen.validate_rule_text(latency) == [], llm_gen.validate_rule_text(latency)

    # Suffix _bucket is not enough: the series is not on the stand.
    invented = _with_expr("histogram_quantile(0.95, sum(rate(not_a_real_histogram_bucket[5m])))")
    errs = llm_gen.validate_rule_text(invented)
    assert any("неизвестная метрика not_a_real_histogram_bucket" in e for e in errs), errs
    assert not any("histogram_quantile" in e for e in errs), errs


def test_repair_receives_whitelist_errors(tmp_path):
    bad = _with_expr('histogram_quantile(0.95, sum(rate(http_requests_total{foo="1"}[5m])))')
    answers = [bad, GOOD]
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
    p = subprocess.run([sys.executable, os.path.join(HERE, "llm_gen.py"), "rule", "5xx",
                        "--out", str(tmp_path / "r.yaml")], env=env, capture_output=True, text=True)
    srv.shutdown()
    assert p.returncode == 0, p.stderr
    repair = seen[1]["messages"][-1]["content"]
    assert "нет метки foo" in repair
    assert "histogram_quantile" in repair
    assert "http_requests_total" in repair


def test_number_match_is_token_not_substring():
    src = "2026-10-16T22:56:54Z FAIL login: HTTP 401"
    # The old check was `n not in src`: 202 is a substring of 2026.
    assert "202" in src
    assert llm_gen.numbers_absent("код 202 в ответе", src) == ["202"]
    assert llm_gen.numbers_absent("год 2026 и код 401", src) == []


def test_explain_rejects_number_inside_date(tmp_path):
    answer = "Код 202 в дате не считается отдельным числом, в логе есть только год."

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            out = json.dumps({"choices": [{"message": {"content": answer}}], "usage": {}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log = tmp_path / "canary.log"
    log.write_text("2026-10-16T22:56:54Z FAIL login: HTTP 401\n", encoding="utf-8")
    env = dict(os.environ, LLM_URL=f"http://127.0.0.1:{srv.server_port}", LLM_LOG=str(tmp_path / "runs.jsonl"))
    p = subprocess.run([sys.executable, os.path.join(HERE, "llm_gen.py"), "explain", str(log)],
                       env=env, capture_output=True, text=True)
    srv.shutdown()
    run = json.loads((tmp_path / "runs.jsonl").read_text())
    assert p.returncode == 1, p.stderr
    assert run["errors"] == ["number not in log: 202"]


def test_log_model_from_loaded_server_not_request_echo(tmp_path):
    seen = []

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps({"object": "list", "data": [{"id": "ternary-bonsai-2-4b", "object": "model"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            seen.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
            # Echo of a stale client label. The journal must keep the loaded id.
            payload = {"choices": [{"message": {"content": GOOD}}], "usage": {},
                       "model": "qwen2.5-coder-1.5b-instruct-q4_k_m"}
            out = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    env = dict(os.environ, LLM_URL=f"http://127.0.0.1:{srv.server_port}",
               LLM_MODEL="qwen2.5-coder-1.5b-instruct-q4_k_m", LLM_LOG=str(tmp_path / "runs.jsonl"))
    p = subprocess.run([sys.executable, os.path.join(HERE, "llm_gen.py"), "rule", "latency",
                        "--no-repair", "--out", str(tmp_path / "r.yaml")],
                       env=env, capture_output=True, text=True)
    srv.shutdown()
    assert p.returncode == 0, p.stderr
    assert seen[0]["model"] == "ternary-bonsai-2-4b"
    run = json.loads((tmp_path / "runs.jsonl").read_text())
    assert run["model"] == "ternary-bonsai-2-4b"


def test_log_model_from_response_then_config(tmp_path):
    # No /v1/models (handler has no GET). Completion names the model: that wins over LLM_MODEL.
    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            payload = {"choices": [{"message": {"content": GOOD}}], "usage": {}, "model": "from-completion"}
            out = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    env = dict(os.environ, LLM_URL=f"http://127.0.0.1:{srv.server_port}",
               LLM_MODEL="from-config", LLM_LOG=str(tmp_path / "runs.jsonl"))
    p = subprocess.run([sys.executable, os.path.join(HERE, "llm_gen.py"), "rule", "latency",
                        "--no-repair", "--out", str(tmp_path / "r.yaml")],
                       env=env, capture_output=True, text=True)
    srv.shutdown()
    assert p.returncode == 0, p.stderr
    assert json.loads((tmp_path / "runs.jsonl").read_text())["model"] == "from-completion"

    class H2(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            payload = {"choices": [{"message": {"content": GOOD}}], "usage": {}}
            out = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    srv2 = http.server.HTTPServer(("127.0.0.1", 0), H2)
    threading.Thread(target=srv2.serve_forever, daemon=True).start()
    log2 = tmp_path / "runs2.jsonl"
    env["LLM_URL"] = f"http://127.0.0.1:{srv2.server_port}"
    env["LLM_LOG"] = str(log2)
    p2 = subprocess.run([sys.executable, os.path.join(HERE, "llm_gen.py"), "rule", "latency",
                         "--no-repair", "--out", str(tmp_path / "r2.yaml")],
                        env=env, capture_output=True, text=True)
    srv2.shutdown()
    assert p2.returncode == 0, p2.stderr
    assert json.loads(log2.read_text())["model"] == "from-config"


def test_explain_logs_prompt_and_checks_only_long_numbers(tmp_path):
    answer = "Канарейка откатилась на весе 50: smoke получил 401, а не 503."

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            out = json.dumps({"choices": [{"message": {"content": answer}}], "usage": {}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log = tmp_path / "canary.log"
    log.write_text("FAIL login: HTTP 401\nROLLBACK canary: smoke failed at weight 10\n", encoding="utf-8")
    env = dict(os.environ, LLM_URL=f"http://127.0.0.1:{srv.server_port}", LLM_LOG=str(tmp_path / "out" / "runs.jsonl"))
    p = subprocess.run([sys.executable, os.path.join(HERE, "llm_gen.py"), "explain", str(log)],
                       env=env, capture_output=True, text=True)
    srv.shutdown()
    run = json.loads((tmp_path / "out" / "runs.jsonl").read_text())
    # 503 is not in the log -> rejected; 50 (two digits) is not checked.
    assert p.returncode == 1
    assert run["errors"] == ["number not in log: 503"]
    assert "ROLLBACK canary" in run["user"]

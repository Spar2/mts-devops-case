import os
import re
import time

# Apply configuration before importing the app. The module builds `app` only when
# DEMO_PASSWORD is already present.
os.environ["DEMO_USERNAME"] = "demo"
os.environ["DEMO_PASSWORD"] = "demo-password-ok"
os.environ["DEMO_DISPLAY_NAME"] = "Демо-участник"
os.environ["SESSION_TTL_S"] = "43200"
os.environ["SECURE_COOKIES"] = "false"

import pytest
from fastapi.testclient import TestClient
from prometheus_client import REGISTRY

from app.main import app, create_app


@pytest.fixture()
def client() -> TestClient:
    assert app is not None
    return TestClient(create_app())


def _login(client: TestClient, username: str = "demo", password: str = "demo-password-ok"):
    return client.post(
        "/api/v1/auth/login",
        json={"username": username, "password": password},
    )


def test_health_and_ready(client: TestClient) -> None:
    health = client.get("/health")
    ready = client.get("/ready")
    assert health.status_code == 200
    assert health.json() == {"status": "ok"}
    assert ready.status_code == 200
    assert ready.json() == {"status": "ok"}


def test_login_bad_password(client: TestClient) -> None:
    response = _login(client, password="not-the-password")
    assert response.status_code == 401
    assert response.json() == {"detail": "Incorrect username or password"}


def test_login_success_sets_cookie(client: TestClient) -> None:
    response = _login(client, username="  DeMo ")
    assert response.status_code == 200
    assert response.json() == {"display_name": "Демо-участник", "role": "analyst"}
    assert response.cookies.get("sensor_session")
    attributes = [part.strip().lower() for part in response.headers["set-cookie"].split(";")]
    assert attributes[0].startswith("sensor_session=")
    assert "httponly" in attributes
    assert "samesite=strict" in attributes
    assert "path=/" in attributes
    assert "max-age=43200" in attributes
    assert "secure" not in attributes


def test_me_without_cookie(client: TestClient) -> None:
    assert client.get("/api/v1/auth/me").status_code == 401


def test_service_without_cookie(client: TestClient) -> None:
    assert client.get("/api/v1/service").status_code == 401


def test_service_with_cookie_synthetic(client: TestClient) -> None:
    assert _login(client).status_code == 200
    response = client.get("/api/v1/service")
    assert response.status_code == 200
    body = response.json()
    assert body["name"] == "sensor-gateway"
    assert body["version"] == "0.1.0"
    assert body["status"] == "ok"
    assert isinstance(body["uptime_s"], (int, float))
    assert body["uptime_s"] >= 0
    assert body["requests"] >= 1
    assert body["last_probe_ms"] is None
    reading = body["reading"]
    assert isinstance(reading["distance_m"], float)
    assert isinstance(reading["temperature_c"], (int, float))
    assert reading["temperature_c"] == round(float(reading["temperature_c"]), 1)
    assert reading["quality"] == "valid"
    assert reading["note"] == "synthetic"


def test_probe(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    assert _login(client).status_code == 200

    def slow_reading(_now: float) -> dict[str, float | str]:
        time.sleep(0.03)
        return {
            "distance_m": 1.0,
            "temperature_c": 21.0,
            "quality": "valid",
            "note": "synthetic",
        }

    monkeypatch.setattr("app.main._synthetic_reading", slow_reading)
    response = client.post("/api/v1/service/probe")
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert body["latency_ms"] >= 25
    gauge = REGISTRY.get_sample_value("service_probe_latency_seconds")
    assert gauge == pytest.approx(body["latency_ms"] / 1000.0, rel=1e-6, abs=1e-6)
    follow = client.get("/api/v1/service")
    assert follow.status_code == 200
    assert isinstance(follow.json()["last_probe_ms"], (int, float))


def test_logout_then_me_401(client: TestClient) -> None:
    login = _login(client)
    assert login.status_code == 200
    token = login.cookies["sensor_session"]
    logged_out = client.post("/api/v1/auth/logout")
    assert logged_out.status_code == 200
    assert logged_out.json() == {"signed_out": True}
    assert client.get("/api/v1/auth/me").status_code == 401
    # Stateless: logout only clears this client's cookie. The token stays valid
    # until exp or DEMO_PASSWORD rotation, including on the same process.
    reused = TestClient(client.app)
    reused.cookies.set("sensor_session", token)
    assert reused.get("/api/v1/auth/me").status_code == 200


def _sample(name: str, labels: dict[str, str]) -> float | None:
    return REGISTRY.get_sample_value(name, labels)


def test_metrics_contains_service_up(client: TestClient) -> None:
    assert client.get("/health").status_code == 200
    assert client.get("/api/v1/service").status_code == 401
    assert client.get("/missing").status_code == 404
    response = client.get("/metrics")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    text = response.text
    assert re.search(r"^service_up 1(?:\.0+)?$", text, re.M)
    assert 'path="/health",status="200"' in text
    assert 'http_request_duration_seconds_bucket{' in text
    assert 'le="0.5"' in text
    health = {"method": "GET", "path": "/health", "status": "200"}
    denied = {"method": "GET", "path": "/api/v1/service", "status": "401"}
    missing = {"method": "GET", "path": "unmatched", "status": "404"}
    assert _sample("http_requests_total", health) >= 1
    assert _sample("http_requests_total", denied) >= 1
    assert _sample("http_requests_total", missing) >= 1
    raw_missing = {"method": "GET", "path": "/missing", "status": "404"}
    assert _sample("http_requests_total", raw_missing) is None
    duration = _sample(
        "http_request_duration_seconds_count",
        {"method": "GET", "path": "/health", "status": "200"},
    )
    assert duration is not None and duration >= 1
    assert "process_resident_memory_bytes" in text


def test_service_up_follows_readiness(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.main._readiness_ok", lambda _settings: False)
    ready = client.get("/ready")
    assert ready.status_code == 503
    text = client.get("/metrics").text
    assert re.search(r"^service_up 0(?:\.0+)?$", text, re.M)


def test_login_rate_limit(client: TestClient) -> None:
    payload = {"username": "demo", "password": "wrong-password1"}
    for _ in range(30):
        response = client.post("/api/v1/auth/login", json=payload)
        assert response.status_code == 401
    blocked = client.post("/api/v1/auth/login", json=payload)
    assert blocked.status_code == 429


def test_create_app_rejects_short_or_missing_password(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DEMO_PASSWORD", "too-short")
    with pytest.raises(RuntimeError):
        create_app()
    monkeypatch.delenv("DEMO_PASSWORD")
    with pytest.raises(RuntimeError):
        create_app()


def test_cookie_accepted_by_second_app_instance(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DEMO_PASSWORD", "demo-password-ok")
    monkeypatch.setenv("SESSION_SECRET", "shared-session-secret")
    first = TestClient(create_app())
    login = _login(first)
    assert login.status_code == 200
    token = login.cookies["sensor_session"]
    second = TestClient(create_app())
    second.cookies.set("sensor_session", token)
    response = second.get("/api/v1/auth/me")
    assert response.status_code == 200
    assert response.json()["username"] == "demo"
    assert response.json()["role"] == "analyst"
    assert second.get("/api/v1/service").status_code == 200


def test_cookie_rejected_after_demo_password_changes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SESSION_SECRET", "shared-session-secret")
    monkeypatch.setenv("DEMO_PASSWORD", "demo-password-ok")
    first = TestClient(create_app())
    token = _login(first).cookies["sensor_session"]
    monkeypatch.setenv("DEMO_PASSWORD", "rotated-password")
    second = TestClient(create_app())
    second.cookies.set("sensor_session", token)
    assert second.get("/api/v1/auth/me").status_code == 401
    assert _login(second, password="rotated-password").status_code == 200


def _wrong_login(client: TestClient, headers: dict[str, str] | None = None):
    return client.post(
        "/api/v1/auth/login",
        json={"username": "demo", "password": "wrong-password1"},
        headers=headers,
    )


def test_login_rate_limit_is_per_client_behind_trusted_proxy() -> None:
    application = create_app()
    proxy = ("10.42.0.8", 40000)
    first = TestClient(application, client=proxy)
    second = TestClient(application, client=proxy)
    for _ in range(30):
        assert _wrong_login(first, {"X-Real-IP": "203.0.113.10"}).status_code == 401
    assert _wrong_login(first, {"X-Real-IP": "203.0.113.10"}).status_code == 429
    assert _wrong_login(second, {"X-Real-IP": "203.0.113.20"}).status_code == 401


def test_same_client_ip_shares_bucket_across_proxy_pods() -> None:
    application = create_app()
    first = TestClient(application, client=("10.42.0.2", 40000))
    second = TestClient(application, client=("10.42.0.3", 40000))
    headers = {"X-Real-IP": "203.0.113.30"}
    for _ in range(30):
        assert _wrong_login(first, headers).status_code == 401
    assert _wrong_login(second, headers).status_code == 429


def test_untrusted_peer_ignores_forwarded_client_ip() -> None:
    application = create_app()
    outsider = TestClient(application, client=("203.0.113.50", 40000))
    for i in range(30):
        assert _wrong_login(outsider, {"X-Real-IP": f"198.51.100.{i + 1}"}).status_code == 401
    blocked = _wrong_login(outsider, {"X-Real-IP": "198.51.100.250"})
    assert blocked.status_code == 429


def test_trusted_proxy_prefers_x_real_ip_and_skips_trusted_forwarded_hops() -> None:
    application = create_app()
    proxy = TestClient(application, client=("10.42.0.9", 40000))
    # No X-Real-IP: the rightmost trusted hop is skipped, the client is 203.0.113.40.
    forwarded = {"X-Forwarded-For": "198.51.100.1, 203.0.113.40, 10.42.1.9"}
    for _ in range(30):
        assert _wrong_login(proxy, forwarded).status_code == 401
    assert _wrong_login(proxy, forwarded).status_code == 429
    other = {"X-Forwarded-For": "203.0.113.40, 198.51.100.9"}
    assert _wrong_login(proxy, other).status_code == 401
    # X-Real-IP wins over a different X-Forwarded-For client.
    real = {"X-Real-IP": "203.0.113.70", "X-Forwarded-For": "198.51.100.70"}
    for _ in range(30):
        assert _wrong_login(proxy, real).status_code == 401
    assert _wrong_login(proxy, real).status_code == 429
    other_real = {"X-Real-IP": "203.0.113.71", "X-Forwarded-For": "198.51.100.70"}
    assert _wrong_login(proxy, other_real).status_code == 401


def test_create_app_rejects_bad_trusted_proxy_cidr(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DEMO_PASSWORD", "demo-password-ok")
    monkeypatch.setenv("TRUSTED_PROXY_CIDRS", "10.42.0.0/16,nope")
    with pytest.raises(RuntimeError, match="TRUSTED_PROXY_CIDRS"):
        create_app()


def test_tampered_session_token_rejected(client: TestClient) -> None:
    token = _login(client).cookies["sensor_session"]
    body, signature = token.split(".", 1)
    flipped_sig = ("A" if signature[:1] != "A" else "B") + signature[1:]
    fresh = TestClient(client.app)
    fresh.cookies.set("sensor_session", f"{body}.{flipped_sig}")
    assert fresh.get("/api/v1/auth/me").status_code == 401
    flipped_body = ("A" if body[:1] != "A" else "B") + body[1:]
    fresh.cookies.set("sensor_session", f"{flipped_body}.{signature}")
    assert fresh.get("/api/v1/auth/me").status_code == 401
    fresh.cookies.set("sensor_session", "not-a-valid-token")
    assert fresh.get("/api/v1/auth/me").status_code == 401
    fresh.cookies.set("sensor_session", f"{body}.")
    assert fresh.get("/api/v1/auth/me").status_code == 401

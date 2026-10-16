import os

# Apply configuration before importing the app. The module builds `app` only when
# DEMO_PASSWORD is already present.
os.environ["DEMO_USERNAME"] = "demo"
os.environ["DEMO_PASSWORD"] = "demo-password-ok"
os.environ["DEMO_DISPLAY_NAME"] = "Демо-участник"
os.environ["SESSION_TTL_S"] = "43200"
os.environ["SECURE_COOKIES"] = "false"

import pytest
from fastapi.testclient import TestClient

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
    assert response.cookies.get("dts_session")
    attributes = [part.strip().lower() for part in response.headers["set-cookie"].split(";")]
    assert attributes[0].startswith("dts_session=")
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


def test_probe(client: TestClient) -> None:
    assert _login(client).status_code == 200
    response = client.post("/api/v1/service/probe")
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert isinstance(body["latency_ms"], (int, float))
    assert body["latency_ms"] >= 0
    follow = client.get("/api/v1/service")
    assert follow.status_code == 200
    assert isinstance(follow.json()["last_probe_ms"], (int, float))


def test_logout_then_me_401(client: TestClient) -> None:
    login = _login(client)
    assert login.status_code == 200
    token = login.cookies["dts_session"]
    logged_out = client.post("/api/v1/auth/logout")
    assert logged_out.status_code == 200
    assert logged_out.json() == {"signed_out": True}
    assert client.get("/api/v1/auth/me").status_code == 401
    # Stateless: logout only clears this client's cookie. The token stays valid
    # until exp or DEMO_PASSWORD rotation, including on the same process.
    reused = TestClient(client.app)
    reused.cookies.set("dts_session", token)
    assert reused.get("/api/v1/auth/me").status_code == 200


def test_metrics_contains_service_up(client: TestClient) -> None:
    response = client.get("/metrics")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    text = response.text
    assert "service_up 1" in text
    assert "http_requests_total" in text
    assert "service_probe_latency_seconds" in text


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
    token = login.cookies["dts_session"]
    second = TestClient(create_app())
    second.cookies.set("dts_session", token)
    response = second.get("/api/v1/auth/me")
    assert response.status_code == 200
    assert response.json()["username"] == "demo"
    assert response.json()["role"] == "analyst"
    assert second.get("/api/v1/service").status_code == 200


def test_cookie_rejected_after_demo_password_changes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SESSION_SECRET", "shared-session-secret")
    monkeypatch.setenv("DEMO_PASSWORD", "demo-password-ok")
    first = TestClient(create_app())
    token = _login(first).cookies["dts_session"]
    monkeypatch.setenv("DEMO_PASSWORD", "rotated-password")
    second = TestClient(create_app())
    second.cookies.set("dts_session", token)
    assert second.get("/api/v1/auth/me").status_code == 401
    assert _login(second, password="rotated-password").status_code == 200


def test_tampered_session_token_rejected(client: TestClient) -> None:
    token = _login(client).cookies["dts_session"]
    body, signature = token.split(".", 1)
    flipped_sig = ("A" if signature[:1] != "A" else "B") + signature[1:]
    fresh = TestClient(client.app)
    fresh.cookies.set("dts_session", f"{body}.{flipped_sig}")
    assert fresh.get("/api/v1/auth/me").status_code == 401
    flipped_body = ("A" if body[:1] != "A" else "B") + body[1:]
    fresh.cookies.set("dts_session", f"{flipped_body}.{signature}")
    assert fresh.get("/api/v1/auth/me").status_code == 401
    fresh.cookies.set("dts_session", "not-a-valid-token")
    assert fresh.get("/api/v1/auth/me").status_code == 401
    fresh.cookies.set("dts_session", f"{body}.")
    assert fresh.get("/api/v1/auth/me").status_code == 401

import asyncio
import base64
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import time
from collections import defaultdict, deque

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel

_LOGIN_LIMIT = 30
_LOGIN_WINDOW_S = 60.0
_PROBE_SLEEP_S = 0.01
_B64URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
# Image tag, same token deploy.sh and canary.sh accept. Anything else falls back
# so a bad env value cannot break the header.
_APP_VERSION_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
_APP_VERSION_DEFAULT = "0.1.0"


class LoginBody(BaseModel):
    username: str
    password: str


class _Settings:
    def __init__(
        self,
        username: str,
        password: str,
        display_name: str,
        session_ttl_s: int,
        secure_cookies: bool,
        signing_key: bytes,
    ) -> None:
        self.username = username
        self.display_name = display_name
        self.session_ttl_s = session_ttl_s
        self.secure_cookies = secure_cookies
        self.signing_key = signing_key
        self._password = password

    def username_ok(self, offered: str) -> bool:
        return _equals(offered.strip().lower(), self.username)

    def password_ok(self, offered: str) -> bool:
        return _equals(offered, self._password)

    def __repr__(self) -> str:
        return f"_Settings(username={self.username!r})"


class _Session:
    def __init__(self, username: str, display_name: str) -> None:
        self.username = username
        self.display_name = display_name
        self.role = "analyst"


def _equals(left: str, right: str) -> bool:
    return secrets.compare_digest(left.encode("utf-8"), right.encode("utf-8"))


def _app_version() -> str:
    raw = os.environ.get("APP_VERSION", "").strip()
    if _APP_VERSION_RE.fullmatch(raw):
        return raw
    return _APP_VERSION_DEFAULT


def _unauthorized() -> HTTPException:
    return HTTPException(status_code=401, detail="Not authenticated")


def _b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64url_decode(text: str) -> bytes | None:
    if not text or any(char not in _B64URL_ALPHABET for char in text):
        return None
    padded = text + ("=" * (-len(text) % 4))
    try:
        return base64.urlsafe_b64decode(padded.encode("ascii"))
    except ValueError:
        return None


def _signing_key(session_secret: str, password: str) -> bytes:
    # sha256((SESSION_SECRET or "") + NUL + DEMO_PASSWORD). Every pod with the
    # same values accepts the cookie. Rotating DEMO_PASSWORD changes the key.
    material = session_secret.encode("utf-8") + b"\0" + password.encode("utf-8")
    return hashlib.sha256(material).digest()


def _settings_from_env() -> _Settings:
    raw_password = os.environ.get("DEMO_PASSWORD")
    if raw_password is None or len(raw_password) < 12:
        raise RuntimeError("DEMO_PASSWORD must be set and at least 12 characters")
    session_secret = os.environ.get("SESSION_SECRET", "")
    if session_secret and len(session_secret) < 16:
        raise RuntimeError("SESSION_SECRET must be at least 16 characters when set")
    username = os.environ.get("DEMO_USERNAME", "demo").strip().lower()
    display_name = os.environ.get("DEMO_DISPLAY_NAME", "Демо-участник")
    try:
        session_ttl_s = int(os.environ.get("SESSION_TTL_S", "43200"))
    except ValueError as exc:
        raise RuntimeError("SESSION_TTL_S must be an integer") from exc
    if session_ttl_s <= 0:
        raise RuntimeError("SESSION_TTL_S must be positive")
    secure_cookies = os.environ.get("SECURE_COOKIES", "false") == "true"
    return _Settings(
        username,
        raw_password,
        display_name,
        session_ttl_s,
        secure_cookies,
        _signing_key(session_secret, raw_password),
    )


def _issue_token(username: str, ttl_s: int, key: bytes) -> str:
    # token = base64url(json{u, exp}) + "." + base64url(HMAC-SHA256(key, body))
    payload = json.dumps(
        {"u": username, "exp": time.time() + ttl_s},
        separators=(",", ":"),
    ).encode("utf-8")
    body = _b64url_encode(payload)
    signature = hmac.new(key, body.encode("ascii"), hashlib.sha256).digest()
    return f"{body}.{_b64url_encode(signature)}"


def _username_from_token(token: str, key: bytes) -> str:
    parts = token.split(".")
    if len(parts) != 2 or not parts[0] or not parts[1]:
        raise _unauthorized()
    body, presented_sig = parts
    presented = _b64url_decode(presented_sig)
    if presented is None or any(char not in _B64URL_ALPHABET for char in body):
        raise _unauthorized()
    expected = hmac.new(key, body.encode("ascii"), hashlib.sha256).digest()
    if len(presented) != len(expected) or not secrets.compare_digest(expected, presented):
        raise _unauthorized()
    raw = _b64url_decode(body)
    if raw is None:
        raise _unauthorized()
    try:
        payload = json.loads(raw)
    except ValueError:
        raise _unauthorized() from None
    if not isinstance(payload, dict):
        raise _unauthorized()
    username = payload.get("u")
    exp = payload.get("exp")
    if not isinstance(username, str) or not username:
        raise _unauthorized()
    if isinstance(exp, bool) or not isinstance(exp, (int, float)) or not math.isfinite(exp):
        raise _unauthorized()
    if exp <= time.time():
        raise _unauthorized()
    return username


def _synthetic_reading(now: float) -> dict[str, float | str]:
    # Deterministic sample derived from the clock. Not loaded from a file.
    angle = (now % 1800.0) / 1800.0 * math.tau
    return {
        "distance_m": round(12.0 + 4.0 * math.sin(angle), 3),
        "temperature_c": round(21.0 + 2.5 * math.cos(angle), 1),
        "quality": "valid",
        "note": "synthetic",
    }


def _session(request: Request) -> _Session:
    token = request.cookies.get("dts_session")
    if not token:
        raise _unauthorized()
    settings: _Settings = request.app.state.settings
    username = _username_from_token(token, settings.signing_key)
    return _Session(username, settings.display_name)


def _login_limited(state, host: str) -> bool:
    now = time.monotonic()
    bucket: deque[float] = state.login_attempts[host]
    cutoff = now - _LOGIN_WINDOW_S
    while bucket and bucket[0] <= cutoff:
        bucket.popleft()
    if len(bucket) >= _LOGIN_LIMIT:
        return True
    bucket.append(now)
    return False


def _metrics_text(state) -> str:
    return "\n".join(
        [
            "# HELP service_up Whether the service process is up.",
            "# TYPE service_up gauge",
            "service_up 1",
            "# HELP http_requests_total Total HTTP requests.",
            "# TYPE http_requests_total counter",
            f"http_requests_total {state.http_requests_total}",
            "# HELP service_probe_latency_seconds Latency of the most recent probe in seconds.",
            "# TYPE service_probe_latency_seconds gauge",
            f"service_probe_latency_seconds {state.probe_latency_seconds:.6f}",
            "",
        ]
    )


def _apply_session_cookie(response: JSONResponse, token: str, settings: _Settings) -> None:
    response.set_cookie(
        key="dts_session",
        value=token,
        httponly=True,
        samesite="strict",
        path="/",
        max_age=settings.session_ttl_s,
        secure=settings.secure_cookies,
    )


def _clear_session_cookie(response: JSONResponse, settings: _Settings) -> None:
    response.delete_cookie(
        key="dts_session",
        path="/",
        httponly=True,
        samesite="strict",
        secure=settings.secure_cookies,
    )


def create_app() -> FastAPI:
    settings = _settings_from_env()
    app = FastAPI(title="sensor-gateway", version="0.1.0")
    app.state.settings = settings
    app.state.started_at = time.monotonic()
    app.state.http_requests_total = 0
    app.state.service_requests = 0
    app.state.probe_count = 0
    app.state.last_probe_ms = None
    app.state.probe_latency_seconds = 0.0
    app.state.login_attempts = defaultdict(deque)

    @app.middleware("http")
    async def count_requests(request: Request, call_next):
        request.app.state.http_requests_total += 1
        return await call_next(request)

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/ready")
    async def ready() -> JSONResponse:
        # APP_VERSION is the image tag (chart env). Smoke and the canary weight
        # sample use it to tell this pod from the other release.
        version = _app_version()
        response = JSONResponse({"status": "ok", "version": version})
        response.headers["X-App-Version"] = version
        return response

    @app.get("/metrics")
    async def metrics(request: Request) -> PlainTextResponse:
        return PlainTextResponse(_metrics_text(request.app.state), media_type="text/plain")

    @app.post("/api/v1/auth/login")
    async def login(body: LoginBody, request: Request) -> JSONResponse:
        host = request.client.host if request.client else "unknown"
        if _login_limited(request.app.state, host):
            raise HTTPException(status_code=429, detail="Too many login attempts")
        current = request.app.state.settings
        if not (current.username_ok(body.username) and current.password_ok(body.password)):
            raise HTTPException(status_code=401, detail="Incorrect username or password")
        token = _issue_token(current.username, current.session_ttl_s, current.signing_key)
        response = JSONResponse(
            {"display_name": current.display_name, "role": "analyst"}
        )
        _apply_session_cookie(response, token, current)
        return response

    @app.post("/api/v1/auth/logout")
    async def logout(request: Request) -> JSONResponse:
        """Clear the dts_session cookie.

        The token is stateless. A copy stays valid until exp or until
        DEMO_PASSWORD rotation changes the signing key.
        """
        response = JSONResponse({"signed_out": True})
        _clear_session_cookie(response, request.app.state.settings)
        return response

    @app.get("/api/v1/auth/me")
    async def me(request: Request) -> dict[str, str]:
        record = _session(request)
        return {
            "username": record.username,
            "display_name": record.display_name,
            "role": record.role,
        }

    @app.get("/api/v1/service")
    async def service(request: Request) -> dict:
        _session(request)
        state = request.app.state
        state.service_requests += 1
        uptime_s = round(time.monotonic() - state.started_at, 3)
        return {
            "name": "sensor-gateway",
            "version": "0.1.0",
            "status": "ok",
            "uptime_s": uptime_s,
            "requests": state.service_requests,
            "last_probe_ms": state.last_probe_ms,
            "reading": _synthetic_reading(time.time()),
        }

    @app.post("/api/v1/service/probe")
    async def service_probe(request: Request) -> dict[str, bool | float]:
        _session(request)
        started = time.perf_counter()
        await asyncio.sleep(_PROBE_SLEEP_S)
        latency_ms = (time.perf_counter() - started) * 1000.0
        state = request.app.state
        state.probe_count += 1
        state.last_probe_ms = latency_ms
        state.probe_latency_seconds = latency_ms / 1000.0
        return {"ok": True, "latency_ms": latency_ms}

    return app


app = create_app() if os.environ.get("DEMO_PASSWORD") else None

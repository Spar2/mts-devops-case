import asyncio
import hashlib
import math
import os
import secrets
import time
from collections import defaultdict, deque

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel

_LOGIN_LIMIT = 30
_LOGIN_WINDOW_S = 60.0
_PROBE_SLEEP_S = 0.01


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
    ) -> None:
        self.username = username
        self.display_name = display_name
        self.session_ttl_s = session_ttl_s
        self.secure_cookies = secure_cookies
        self._password = password

    def username_ok(self, offered: str) -> bool:
        return _equals(offered.strip().lower(), self.username)

    def password_ok(self, offered: str) -> bool:
        return _equals(offered, self._password)

    def __repr__(self) -> str:
        return f"_Settings(username={self.username!r})"


class _Session:
    def __init__(self, username: str, display_name: str, expires_at: float) -> None:
        self.username = username
        self.display_name = display_name
        self.role = "analyst"
        self.expires_at = expires_at


def _equals(left: str, right: str) -> bool:
    return secrets.compare_digest(left.encode("utf-8"), right.encode("utf-8"))


def _settings_from_env() -> _Settings:
    raw_password = os.environ.get("DEMO_PASSWORD")
    if raw_password is None or len(raw_password) < 12:
        raise RuntimeError("DEMO_PASSWORD must be set and at least 12 characters")
    username = os.environ.get("DEMO_USERNAME", "demo").strip().lower()
    display_name = os.environ.get("DEMO_DISPLAY_NAME", "Демо-участник")
    try:
        session_ttl_s = int(os.environ.get("SESSION_TTL_S", "43200"))
    except ValueError as exc:
        raise RuntimeError("SESSION_TTL_S must be an integer") from exc
    if session_ttl_s <= 0:
        raise RuntimeError("SESSION_TTL_S must be positive")
    secure_cookies = os.environ.get("SECURE_COOKIES", "false") == "true"
    return _Settings(username, raw_password, display_name, session_ttl_s, secure_cookies)


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


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
        raise HTTPException(status_code=401, detail="Not authenticated")
    state = request.app.state
    record = state.sessions.get(_token_hash(token))
    if record is None or record.expires_at <= time.monotonic():
        if record is not None:
            state.sessions.pop(_token_hash(token), None)
        raise HTTPException(status_code=401, detail="Not authenticated")
    return record


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
    app.state.sessions = {}
    app.state.login_attempts = defaultdict(deque)

    @app.middleware("http")
    async def count_requests(request: Request, call_next):
        request.app.state.http_requests_total += 1
        return await call_next(request)

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/ready")
    async def ready() -> dict[str, str]:
        return {"status": "ok"}

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
        token = secrets.token_urlsafe(32)
        request.app.state.sessions[_token_hash(token)] = _Session(
            username=current.username,
            display_name=current.display_name,
            expires_at=time.monotonic() + current.session_ttl_s,
        )
        response = JSONResponse(
            {"display_name": current.display_name, "role": "analyst"}
        )
        _apply_session_cookie(response, token, current)
        return response

    @app.post("/api/v1/auth/logout")
    async def logout(request: Request) -> JSONResponse:
        token = request.cookies.get("dts_session")
        if token:
            request.app.state.sessions.pop(_token_hash(token), None)
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

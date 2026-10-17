import base64
import hashlib
import hmac
import ipaddress
import json
import math
import os
import secrets
import time
from collections import defaultdict, deque

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from pydantic import BaseModel

_LOGIN_LIMIT = 30
_LOGIN_WINDOW_S = 60.0
_SESSION_COOKIE = "sensor_session"
_B64URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
# k3s defaults: pod CIDR 10.42.0.0/16, service CIDR 10.43.0.0/16.
# Web pods live in the pod CIDR, so they are the trusted hop in front of the API.
_DEFAULT_TRUSTED_PROXY_CIDRS = "10.42.0.0/16,10.43.0.0/16"
_Network = ipaddress.IPv4Network | ipaddress.IPv6Network

# Default registry also exports process_* and python_*.
HTTP_REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests.",
    ("method", "path", "status"),
)
HTTP_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ("method", "path", "status"),
)
SERVICE_UP = Gauge(
    "service_up",
    "1 when the readiness check passes, otherwise 0.",
)
PROBE_LATENCY = Gauge(
    "service_probe_latency_seconds",
    "Latency of the most recent service probe in seconds.",
)


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
        trusted_proxies: tuple[_Network, ...],
    ) -> None:
        self.username = username
        self.display_name = display_name
        self.session_ttl_s = session_ttl_s
        self.secure_cookies = secure_cookies
        self.signing_key = signing_key
        self.trusted_proxies = trusted_proxies
        self._password = password

    def username_ok(self, offered: str) -> bool:
        return _equals(offered.strip().lower(), self.username)

    def password_ok(self, offered: str) -> bool:
        return _equals(offered, self._password)


class _Session:
    def __init__(self, username: str, display_name: str) -> None:
        self.username = username
        self.display_name = display_name
        self.role = "analyst"


def _equals(left: str, right: str) -> bool:
    return secrets.compare_digest(left.encode("utf-8"), right.encode("utf-8"))


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


def _trusted_networks(raw: str | None) -> tuple[_Network, ...]:
    if raw is None or not raw.strip():
        raw = _DEFAULT_TRUSTED_PROXY_CIDRS
    networks: list[_Network] = []
    for part in raw.split(","):
        item = part.strip()
        if not item:
            continue
        try:
            networks.append(ipaddress.ip_network(item, strict=False))
        except ValueError as exc:
            raise RuntimeError(f"TRUSTED_PROXY_CIDRS has an invalid network: {item}") from exc
    if not networks:
        raise RuntimeError("TRUSTED_PROXY_CIDRS must list at least one network")
    return tuple(networks)


def _parse_ip(text: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        return ipaddress.ip_address(text.strip())
    except ValueError:
        return None


def _in_trusted(
    addr: ipaddress.IPv4Address | ipaddress.IPv6Address,
    networks: tuple[_Network, ...],
) -> bool:
    return any(addr in network for network in networks)


def _client_from_forwarded(header: str, networks: tuple[_Network, ...]) -> str | None:
    # Rightmost address is the one appended by the nearest proxy. Skip hops that
    # are themselves trusted proxies; the first address outside that set is the client.
    addresses: list[ipaddress.IPv4Address | ipaddress.IPv6Address] = []
    for part in header.split(","):
        addr = _parse_ip(part)
        if addr is not None:
            addresses.append(addr)
    if not addresses:
        return None
    for addr in reversed(addresses):
        if not _in_trusted(addr, networks):
            return str(addr)
    return str(addresses[0])


def _client_address(request: Request, networks: tuple[_Network, ...]) -> str:
    # Headers count only when the TCP peer is a trusted proxy. Then X-Real-IP
    # is that proxy's client. Otherwise the rightmost untrusted X-Forwarded-For
    # hop is the client. A forged header from an untrusted peer is ignored.
    peer = request.client.host if request.client and request.client.host else "unknown"
    peer_addr = _parse_ip(peer)
    if peer_addr is None or not _in_trusted(peer_addr, networks):
        return peer
    real = _parse_ip(request.headers.get("x-real-ip", ""))
    if real is not None:
        return str(real)
    forwarded = _client_from_forwarded(request.headers.get("x-forwarded-for", ""), networks)
    if forwarded is not None:
        return forwarded
    return peer


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
        _trusted_networks(os.environ.get("TRUSTED_PROXY_CIDRS")),
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


def _readiness_ok(settings: _Settings) -> bool:
    # The process has no remote dependency. Readiness is the session key:
    # it must be present and able to issue a token that verifies.
    if not settings.username or len(settings.signing_key) != 32:
        return False
    try:
        token = _issue_token(settings.username, 60, settings.signing_key)
        return _username_from_token(token, settings.signing_key) == settings.username
    except HTTPException:
        return False


def _route_path(scope: dict) -> str:
    # Route template, not the raw URL, so a 404 cannot grow the label set.
    route = scope.get("route")
    path = getattr(route, "path", None)
    if isinstance(path, str) and path:
        return path
    return "unmatched"


class _ObserveHttp:
    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        method = scope.get("method", "GET")
        status = 500
        started = time.perf_counter()

        async def send_wrapper(message):
            nonlocal status
            if message["type"] == "http.response.start":
                status = int(message["status"])
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            elapsed = time.perf_counter() - started
            labels = {
                "method": method,
                "path": _route_path(scope),
                "status": str(status),
            }
            HTTP_REQUESTS.labels(**labels).inc()
            HTTP_DURATION.labels(**labels).observe(elapsed)


def _session(request: Request) -> _Session:
    token = request.cookies.get(_SESSION_COOKIE)
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


def _apply_session_cookie(response: JSONResponse, token: str, settings: _Settings) -> None:
    response.set_cookie(
        key=_SESSION_COOKIE,
        value=token,
        httponly=True,
        samesite="strict",
        path="/",
        max_age=settings.session_ttl_s,
        secure=settings.secure_cookies,
    )


def _clear_session_cookie(response: JSONResponse, settings: _Settings) -> None:
    response.delete_cookie(
        key=_SESSION_COOKIE,
        path="/",
        httponly=True,
        samesite="strict",
        secure=settings.secure_cookies,
    )


def _mark_readiness(settings: _Settings) -> bool:
    ok = _readiness_ok(settings)
    SERVICE_UP.set(1 if ok else 0)
    return ok


def create_app() -> FastAPI:
    settings = _settings_from_env()
    app = FastAPI(title="sensor-gateway", version="0.1.0")
    app.state.settings = settings
    app.state.started_at = time.monotonic()
    app.state.service_requests = 0
    app.state.last_probe_ms = None
    app.state.login_attempts = defaultdict(deque)
    app.add_middleware(_ObserveHttp)
    _mark_readiness(settings)

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/ready")
    async def ready(request: Request) -> dict[str, str]:
        if not _mark_readiness(request.app.state.settings):
            raise HTTPException(status_code=503, detail="not ready")
        return {"status": "ok"}

    @app.get("/metrics")
    async def metrics(request: Request) -> Response:
        _mark_readiness(request.app.state.settings)
        return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

    @app.post("/api/v1/auth/login")
    async def login(body: LoginBody, request: Request) -> JSONResponse:
        current: _Settings = request.app.state.settings
        host = _client_address(request, current.trusted_proxies)
        if _login_limited(request.app.state, host):
            raise HTTPException(status_code=429, detail="Too many login attempts")
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
        """Clear the sensor_session cookie.

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
        reading = _synthetic_reading(time.time())
        elapsed = time.perf_counter() - started
        state = request.app.state
        state.last_probe_ms = elapsed * 1000.0
        PROBE_LATENCY.set(elapsed)
        return {"ok": reading["quality"] == "valid", "latency_ms": state.last_probe_ms}

    return app


app = create_app() if os.environ.get("DEMO_PASSWORD") else None

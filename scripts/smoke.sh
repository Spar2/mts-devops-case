#!/usr/bin/env bash
# Smoke-test sensor-gateway through the ingress.
#
# Usage: smoke.sh [BASE_URL]
#   Default: http://sensor.localtest.me:${INGRESS_PORT:-80}
#   When no argument is given, an exported BASE_URL wins over that default.
#
# DEMO_PASSWORD     login password. If unset, read key DEMO_PASSWORD from
#                   secret sensor-secrets in namespace sensor.
# DEMO_USERNAME     default demo
# X_CANARY          if set, send "X-Canary: <value>" on every request
# READY_TIMEOUT_S   seconds to wait for GET /ready (default 60)

set -euo pipefail

usage() {
  printf 'usage: %s [BASE_URL]\n' "${0##*/}" >&2
}

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

if [[ $# -eq 1 ]]; then
  BASE_URL=$1
elif [[ -z "${BASE_URL:-}" ]]; then
  ingress_port="${INGRESS_PORT:-80}"
  if [[ ! "$ingress_port" =~ ^[0-9]+$ ]] || ((10#$ingress_port < 1 || 10#$ingress_port > 65535)); then
    printf 'INGRESS_PORT must be a TCP port\n' >&2
    exit 2
  fi
  BASE_URL="http://sensor.localtest.me:${ingress_port}"
fi
BASE_URL="${BASE_URL%/}"

if [[ ! "$BASE_URL" =~ ^https?://[^[:space:]]+$ ]]; then
  printf 'BASE_URL must be an http(s) URL without spaces: %s\n' "$BASE_URL" >&2
  exit 2
fi

ready_timeout="${READY_TIMEOUT_S:-60}"
if [[ ! "$ready_timeout" =~ ^[1-9][0-9]*$ ]]; then
  printf 'READY_TIMEOUT_S must be a positive integer\n' >&2
  exit 2
fi

if [[ -n "${X_CANARY:-}" && ! "${X_CANARY}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'X_CANARY must be a single token\n' >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  printf 'curl is required\n' >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
body_file="${work}/body"
err_file="${work}/err"
hdr_file="${work}/headers"
failures=0
password=""
session=""

curl_common=(
  --silent
  --show-error
  --connect-timeout 3
  --max-time 10
  --globoff
)
if [[ -n "${X_CANARY:-}" ]]; then
  curl_common+=(-H "X-Canary: ${X_CANARY}")
fi

pass() {
  printf 'PASS %s\n' "$*"
}

fail() {
  printf 'FAIL %s\n' "$*"
  failures=$((failures + 1))
}

# Print the HTTP status, or 000 when curl cannot get a status line.
curl_status() {
  local url=$1
  shift
  local status
  : >"$err_file"
  status="$(
    curl "${curl_common[@]}" \
      -o "$body_file" \
      -w '%{http_code}' \
      "$@" \
      "$url" 2>"$err_file" || true
  )"
  if [[ ! "$status" =~ ^[0-9]{3}$ ]]; then
    status=000
  fi
  printf '%s' "$status"
}

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

read_secret_password() {
  local encoded decoded
  if ! encoded="$(kubectl get secret sensor-secrets -n sensor -o jsonpath='{.data.DEMO_PASSWORD}' 2>/dev/null)"; then
    return 1
  fi
  if [[ -z "$encoded" ]]; then
    return 1
  fi
  if ! decoded="$(printf '%s' "$encoded" | base64 -d 2>/dev/null)"; then
    return 1
  fi
  if [[ -z "$decoded" ]]; then
    return 1
  fi
  printf '%s' "$decoded"
}

check_ready() {
  local deadline status
  deadline=$((SECONDS + ready_timeout))
  status=000
  printf 'waiting up to %ss for %s/ready\n' "$ready_timeout" "$BASE_URL" >&2
  while ((SECONDS < deadline)); do
    status="$(curl_status "${BASE_URL}/ready")"
    if [[ "$status" == "200" ]]; then
      pass "ready 200"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      break
    fi
    sleep 2
  done
  fail "ready: HTTP ${status} after ${ready_timeout}s, expected 200"
}

check_metrics() {
  local status
  status="$(curl_status "${BASE_URL}/metrics")"
  # "service_up 1" as its own sample. Do not treat "service_up 10" as up.
  if [[ "$status" == "200" ]] && grep -Eq 'service_up 1([^0-9]|$)' "$body_file"; then
    pass "metrics contains service_up 1"
    return 0
  fi
  fail "metrics: HTTP ${status}, expected body to contain service_up 1"
}

check_service_unauth() {
  local status
  status="$(curl_status "${BASE_URL}/api/v1/service")"
  if [[ "$status" == "401" ]]; then
    pass "GET /api/v1/service without cookie 401"
    return 0
  fi
  fail "GET /api/v1/service without cookie: HTTP ${status}, expected 401"
}

load_password() {
  local value
  if [[ -n "${DEMO_PASSWORD:-}" ]]; then
    value="$DEMO_PASSWORD"
  elif ! value="$(read_secret_password)"; then
    fail "login: DEMO_PASSWORD is unset and secret sensor-secrets in namespace sensor is unreadable"
    return 1
  fi
  if [[ ${#value} -lt 12 ]]; then
    fail "login: DEMO_PASSWORD must be at least 12 characters"
    return 1
  fi
  password="$value"
}

# FastAPI sets dts_session on POST /api/v1/auth/login.
session_from_headers() {
  local line value
  line="$(grep -i -m1 '^set-cookie:[[:space:]]*dts_session=' "$hdr_file" || true)"
  if [[ -z "$line" ]]; then
    printf ''
    return 0
  fi
  value="${line#*=}"
  value="${value%%;*}"
  value="${value%%$'\r'}"
  printf '%s' "$value"
}

check_login() {
  local username status token
  username="${DEMO_USERNAME:-demo}"
  printf '{"username":"%s","password":"%s"}' \
    "$(json_escape "$username")" \
    "$(json_escape "$password")" >"${work}/login.json"
  : >"$hdr_file"
  # Cookie header, not a cookie jar: curl will not resend a Secure cookie on http://.
  status="$(
    curl_status "${BASE_URL}/api/v1/auth/login" \
      -D "$hdr_file" \
      -H 'Content-Type: application/json' \
      --data-binary @"${work}/login.json"
  )"
  token="$(session_from_headers)"
  if [[ "$status" == "200" && "$token" =~ ^[A-Za-z0-9._-]+$ ]]; then
    session="$token"
    pass "login cookie dts_session"
    return 0
  fi
  session=""
  fail "login: HTTP ${status}, expected 200 and cookie dts_session"
}

check_service_auth() {
  local status
  status="$(curl_status "${BASE_URL}/api/v1/service" -H "Cookie: dts_session=${session}")"
  if [[ "$status" == "200" ]]; then
    pass "GET /api/v1/service with cookie 200"
    return 0
  fi
  fail "GET /api/v1/service with cookie: HTTP ${status}, expected 200"
}

check_probe() {
  local status
  status="$(
    curl_status "${BASE_URL}/api/v1/service/probe" \
      -X POST \
      -H "Cookie: dts_session=${session}"
  )"
  if [[ "$status" == "200" ]]; then
    pass "POST /api/v1/service/probe 200"
    return 0
  fi
  fail "POST /api/v1/service/probe: HTTP ${status}, expected 200"
}

skip_authed() {
  fail "GET /api/v1/service with cookie: no session"
  fail "POST /api/v1/service/probe: no session"
}

check_ready
check_metrics
check_service_unauth
if load_password; then
  check_login
fi
if [[ -n "$session" ]]; then
  check_service_auth
  check_probe
else
  skip_authed
fi

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

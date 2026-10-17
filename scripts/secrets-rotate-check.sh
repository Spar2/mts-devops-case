#!/usr/bin/env bash
# End-to-end проверка ротации DEMO_PASSWORD в кластере:
# старый пароль и старая cookie перестают работать, новый пароль пускает.
# BASE_URL по умолчанию http://sensor.localtest.me:${INGRESS_PORT:-80}
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
base="${BASE_URL:-http://sensor.localtest.me:${INGRESS_PORT:-80}}"
c() { curl -s --noproxy '*' -m 10 "$@"; }
pw() { kubectl -n sensor get secret sensor-secrets -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d; }
login() { # $1 password -> prints "status cookie"
  local hdr status
  hdr="$(mktemp)"
  status="$(c -o /dev/null -D "${hdr}" -w '%{http_code}' -H 'Content-Type: application/json' \
    -d "{\"username\":\"demo\",\"password\":\"$1\"}" "${base}/api/v1/auth/login")"
  printf '%s %s\n' "${status}" "$(grep -i -m1 '^set-cookie: *sensor_session=' "${hdr}" | sed 's/^[^=]*=//; s/;.*//' | tr -d '\r')"
  rm -f "${hdr}"
}
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1 ($2)"; else echo "FAIL $1: got $2, want $3"; failed=1; fi; }
failed=0

old_pw="$(pw)"
# Строку обрабатывает только раннер Actions (локальный CI=true пароль не печатает).
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  printf '::add-mask::%s\n' "${old_pw}"
fi
read -r st old_cookie < <(login "${old_pw}")
check "вход со старым паролем до ротации" "${st}" 200
check "старая cookie до ротации" "$(c -o /dev/null -w '%{http_code}' -H "Cookie: sensor_session=${old_cookie}" "${base}/api/v1/service")" 200

"${root}/scripts/secrets-rotate.sh" >/dev/null
for _ in $(seq 1 30); do [[ "$(c -o /dev/null -w '%{http_code}' "${base}/ready")" == 200 ]] && break; sleep 2; done
new_pw="$(pw)"
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  printf '::add-mask::%s\n' "${new_pw}"
fi
if [[ "${new_pw}" != "${old_pw}" ]]; then echo "PASS пароль в Secret сменился"; else echo "FAIL пароль не сменился"; failed=1; fi

read -r st _ < <(login "${old_pw}")
check "вход со старым паролем после ротации" "${st}" 401
check "старая cookie после ротации" "$(c -o /dev/null -w '%{http_code}' -H "Cookie: sensor_session=${old_cookie}" "${base}/api/v1/service")" 401
read -r st new_cookie < <(login "${new_pw}")
check "вход с новым паролем" "${st}" 200
check "новая cookie" "$(c -o /dev/null -w '%{http_code}' -H "Cookie: sensor_session=${new_cookie}" "${base}/api/v1/service")" 200
exit "${failed}"

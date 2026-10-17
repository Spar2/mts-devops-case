#!/usr/bin/env bash
# Сценарии отката scripts/deploy.sh без кластера: helm и kubectl — заглушки в PATH.
# Smoke бьёт в локальный HTTP 500, поэтому релиз после helm upgrade считается проваленным.
# Запуск: ./scripts/test-deploy-rollback.sh  (его вызывает make lint).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'kill "${http_pid:-}" 2>/dev/null || true; rm -rf -- "${work}"' EXIT

portfile="${work}/port"
python3 - "${portfile}" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

portfile = sys.argv[1]

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(500)
        self.end_headers()

    def do_POST(self):
        self.send_response(500)
        self.end_headers()

    def log_message(self, fmt, *args):
        return

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(portfile, "w", encoding="ascii") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
PY
http_pid=$!

for _ in $(seq 1 50); do
  if [[ -s "${portfile}" ]]; then
    break
  fi
  sleep 0.05
done
if [[ ! -s "${portfile}" ]]; then
  printf 'test-deploy-rollback: локальный HTTP не поднялся\n' >&2
  exit 1
fi
port="$(cat "${portfile}")"

bindir="${work}/bin"
mkdir -p "${bindir}"
helm_log="${work}/helm.log"
kubectl_log="${work}/kubectl.log"

cat >"${bindir}/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${HELM_LOG:?}"
case "$1" in
  upgrade) exit 0 ;;
  history)
    if [[ "${HELM_HISTORY_FAIL:-0}" == 1 ]]; then
      printf 'history failed\n' >&2
      exit 1
    fi
    printf '%s\n' "${HELM_HISTORY_JSON:-[]}"
    exit 0
    ;;
  rollback)
    if [[ "${HELM_ROLLBACK_FAIL:-0}" == 1 ]]; then
      printf 'rollback failed\n' >&2
      exit 1
    fi
    exit 0
    ;;
  uninstall)
    if [[ "${HELM_UNINSTALL_FAIL:-0}" == 1 ]]; then
      printf 'uninstall failed\n' >&2
      exit 1
    fi
    exit 0
    ;;
  *)
    printf 'unexpected helm command: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOF

cat >"${bindir}/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${KUBECTL_LOG:?}"
exit 1
EOF
chmod 0755 "${bindir}/helm" "${bindir}/kubectl"

fail() {
  printf 'FAIL %s\n' "$*" >&2
  printf '--- stdout ---\n%s\n--- stderr ---\n%s\n--- helm log ---\n%s\n' \
    "$(cat "${work}/out")" "$(cat "${work}/err")" "$(cat "${helm_log}")" >&2
  exit 1
}

assert_grep() {
  local file="$1" pattern="$2" title="$3"
  if ! grep -Eq -- "${pattern}" "${file}"; then
    fail "${title}: нет /${pattern}/"
  fi
}

assert_not_grep() {
  local file="$1" pattern="$2" title="$3"
  if grep -Eq -- "${pattern}" "${file}"; then
    fail "${title}: лишнее /${pattern}/"
  fi
}

run_case() {
  local name="$1" expect_code="$2"
  : >"${helm_log}"
  : >"${kubectl_log}"
  : >"${work}/out"
  : >"${work}/err"
  set +e
  PATH="${bindir}:${PATH}" \
    HELM_LOG="${helm_log}" \
    KUBECTL_LOG="${kubectl_log}" \
    HELM_HISTORY_JSON="${HELM_HISTORY_JSON:-}" \
    HELM_HISTORY_FAIL="${HELM_HISTORY_FAIL:-0}" \
    HELM_ROLLBACK_FAIL="${HELM_ROLLBACK_FAIL:-0}" \
    HELM_UNINSTALL_FAIL="${HELM_UNINSTALL_FAIL:-0}" \
    DEMO_PASSWORD="deploy-rollback-test" \
    READY_TIMEOUT_S=1 \
    BASE_URL="http://127.0.0.1:${port}" \
    "${root}/scripts/deploy.sh" testtag >"${work}/out" 2>"${work}/err"
  local code=$?
  set -e
  if [[ "${code}" -ne "${expect_code}" ]]; then
    fail "${name}: код ${code}, ожидался ${expect_code}"
  fi
  if [[ -s "${kubectl_log}" ]]; then
    fail "${name}: kubectl вызывался: $(cat "${kubectl_log}")"
  fi
  assert_grep "${helm_log}" '^upgrade ' "${name}"
  printf 'PASS %s\n' "${name}"
}

HELM_HISTORY_JSON='[]'
HELM_HISTORY_FAIL=0
HELM_ROLLBACK_FAIL=0
HELM_UNINSTALL_FAIL=0
run_case "no revisions -> uninstall" 1
assert_grep "${helm_log}" '^uninstall ' "no revisions"
assert_not_grep "${helm_log}" '^rollback ' "no revisions"
assert_grep "${work}/err" 'helm uninstall sensor' "no revisions"
assert_not_grep "${work}/err" 'error: helm uninstall' "no revisions"

HELM_HISTORY_JSON='[{"revision":1,"status":"deployed"}]'
run_case "one revision -> uninstall" 1
assert_grep "${helm_log}" '^uninstall ' "one revision"
assert_not_grep "${helm_log}" '^rollback ' "one revision"

HELM_HISTORY_JSON='not-json'
run_case "invalid history json -> uninstall" 1
assert_grep "${helm_log}" '^uninstall ' "invalid json"
assert_not_grep "${helm_log}" '^rollback ' "invalid json"

HELM_HISTORY_JSON='{"revision":1}'
run_case "history object, not a list -> uninstall" 1
assert_grep "${helm_log}" '^uninstall ' "history object"

HELM_HISTORY_FAIL=1
HELM_HISTORY_JSON='[{"revision":1},{"revision":2}]'
run_case "helm history fails -> uninstall" 1
assert_grep "${helm_log}" '^history ' "history fails"
assert_grep "${helm_log}" '^uninstall ' "history fails"
assert_not_grep "${helm_log}" '^rollback ' "history fails"
assert_not_grep "${work}/err" 'error: helm uninstall' "history fails"

HELM_HISTORY_FAIL=0
HELM_HISTORY_JSON='[{"revision":1},{"revision":2}]'
run_case "two revisions -> rollback" 1
assert_grep "${helm_log}" '^rollback sensor 0 -n sensor --wait$' "two revisions"
assert_not_grep "${helm_log}" '^uninstall ' "two revisions"
assert_grep "${work}/err" 'helm rollback sensor 0' "two revisions"
assert_not_grep "${work}/err" 'error: helm rollback' "two revisions"

HELM_ROLLBACK_FAIL=1
run_case "rollback failure is a hard error" 1
assert_grep "${work}/err" 'error: helm rollback sensor 0 -n sensor --wait failed' "rollback failure"
assert_not_grep "${helm_log}" '^uninstall ' "rollback failure"

HELM_ROLLBACK_FAIL=0
HELM_HISTORY_JSON='[{"revision":1}]'
HELM_UNINSTALL_FAIL=1
run_case "uninstall failure is a hard error" 1
assert_grep "${work}/err" 'error: helm uninstall sensor -n sensor --wait failed' "uninstall failure"
assert_not_grep "${helm_log}" '^rollback ' "uninstall failure"

printf 'PASS test-deploy-rollback\n'

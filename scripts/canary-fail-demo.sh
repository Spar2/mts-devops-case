#!/usr/bin/env bash
# Canary pods become ready, smoke login fails, canary.sh rolls the canary back.
#
# Creates Secret sensor-secrets-wrong (key DEMO_PASSWORD, 20 random hex
# characters) and runs canary.sh with
# CANARY_HELM_ARGS="--set existingSecret=sensor-secrets-wrong".
# The canary Deployment starts: the Secret exists, so kubelet can inject
# DEMO_PASSWORD and /ready succeeds. smoke.sh does not use that Secret. It
# reads DEMO_PASSWORD from Secret sensor-secrets, which is the stable
# password, so login against the canary fails. canary.sh sets weight 0,
# uninstalls sensor-canary, and leaves release sensor as it was.
# Then helm list -n sensor (only sensor remains) and a stable smoke.
#
# Usage: canary-fail-demo.sh [TAG]
#   TAG                 image tag for the canary. Default: tag of the running
#                       sensor-api container. IMAGE_REPO_PREFIX is then the
#                       registry prefix of that image.
#   DEMO_PASSWORD       ignored for both smokes. Unset for the child processes
#                       so smoke.sh reads Secret sensor-secrets.

set -euo pipefail

usage() {
  printf 'usage: %s [TAG]\n' "${0##*/}" >&2
}

now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

step() {
  printf '%s %s\n' "$(now)" "$*"
}

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

command -v helm >/dev/null 2>&1 || {
  printf 'helm is required\n' >&2
  exit 1
}
command -v kubectl >/dev/null 2>&1 || {
  printf 'kubectl is required\n' >&2
  exit 1
}
command -v openssl >/dev/null 2>&1 || {
  printf 'openssl is required\n' >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  printf 'curl is required\n' >&2
  exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secret_file=""
log=""
cleanup() {
  if [[ -n "$secret_file" ]]; then
    rm -f -- "$secret_file"
  fi
  if [[ -n "$log" ]]; then
    rm -f -- "$log"
  fi
}
trap cleanup EXIT

tag=""
if [[ $# -eq 1 ]]; then
  tag=$1
  step "using tag ${tag}"
else
  image="$(
    kubectl get deploy sensor-api -n sensor \
      -o jsonpath='{.spec.template.spec.containers[0].image}'
  )"
  if [[ -z "$image" || "$image" != *:* ]]; then
    printf 'deploy/sensor-api in namespace sensor has no image tag\n' >&2
    exit 1
  fi
  tag="${image##*:}"
  repo="${image%:*}"
  case "$repo" in
    */sensor-gateway)
      IMAGE_REPO_PREFIX="${repo%/sensor-gateway}"
      export IMAGE_REPO_PREFIX
      ;;
    *)
      printf 'sensor-api image is not <prefix>/sensor-gateway:<tag>: %s\n' "$image" >&2
      exit 1
      ;;
  esac
  step "using tag ${tag} from deploy/sensor-api (${image})"
fi

if [[ ! "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  printf 'TAG is not a valid image tag: %s\n' "$tag" >&2
  exit 2
fi

# 20 hex characters. openssl rand -hex 10 prints that and a newline, which
# command substitution strips. The value only has to differ from sensor-secrets.
password="$(openssl rand -hex 10)"
if [[ ${#password} -ne 20 || ! "$password" =~ ^[0-9a-f]{20}$ ]]; then
  printf 'openssl did not return 20 hex characters\n' >&2
  exit 1
fi

step "creating Secret sensor-secrets-wrong in namespace sensor"
kubectl create namespace sensor --dry-run=client -o yaml | kubectl apply -f -
secret_file="$(mktemp)"
chmod 600 "$secret_file"
cat >"$secret_file" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: sensor-secrets-wrong
  namespace: sensor
type: Opaque
stringData:
  DEMO_PASSWORD: "${password}"
EOF
kubectl apply -f "$secret_file"
rm -f -- "$secret_file"
secret_file=""
unset password

log="$(mktemp)"
step "running canary.sh; smoke login should fail and roll the canary back"
set +e
env -u DEMO_PASSWORD \
  CANARY_HELM_ARGS="--set existingSecret=sensor-secrets-wrong" \
  "${ROOT}/scripts/canary.sh" "$tag" | tee "$log"
status=${PIPESTATUS[0]}
set -e

if [[ "$status" -eq 0 ]]; then
  printf 'FAIL canary-fail-demo: canary.sh exited 0, expected rollback\n' >&2
  exit 1
fi
if ! grep -F 'ROLLBACK canary:' "$log" >/dev/null; then
  printf 'FAIL canary-fail-demo: canary.sh exited %s without rollback\n' "$status" >&2
  exit 1
fi
step "canary.sh rolled back (exit ${status})"

step "helm list -n sensor"
helm list -n sensor

if helm status sensor-canary -n sensor >/dev/null 2>&1; then
  printf 'FAIL canary-fail-demo: release sensor-canary is still installed\n' >&2
  exit 1
fi
if ! helm status sensor -n sensor >/dev/null 2>&1; then
  printf 'FAIL canary-fail-demo: stable release sensor is missing\n' >&2
  exit 1
fi
step "only stable release sensor remains"

# X-Canary: never pins the ingress to stable while a canary Ingress exists.
# DEMO_PASSWORD is unset so smoke.sh reads Secret sensor-secrets, the stable one.
step "smoke stable release sensor"
if ! env -u DEMO_PASSWORD X_CANARY=never "${ROOT}/scripts/smoke.sh"; then
  printf 'FAIL canary-fail-demo: stable smoke failed\n' >&2
  exit 1
fi
step "PASS canary-fail-demo: stable release sensor still serves traffic"

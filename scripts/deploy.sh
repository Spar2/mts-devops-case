#!/usr/bin/env bash
# Upgrade the stable release "sensor", smoke-test it, and roll back on failure.
#
# Usage: deploy.sh TAG
#   IMAGE_REPO_PREFIX  registry prefix, default ghcr.io/spar2/mts-devops-case
#   HELM_ARGS          extra helm arguments, split on whitespace
#
# Images:
#   ${IMAGE_REPO_PREFIX}/sensor-gateway:${TAG}
#   ${IMAGE_REPO_PREFIX}/sensor-web:${TAG}

set -euo pipefail

usage() {
  printf 'usage: %s TAG\n' "${0##*/}" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

TAG=$1
if [[ ! "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  printf 'TAG is not a valid image tag: %s\n' "$TAG" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="${ROOT}/deploy/helm/sensor-gateway"

prefix="${IMAGE_REPO_PREFIX:-ghcr.io/spar2/mts-devops-case}"
prefix="${prefix%/}"
if [[ ! "$prefix" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
  printf 'IMAGE_REPO_PREFIX is not a repository prefix: %s\n' "$prefix" >&2
  exit 2
fi

extra=()
if [[ "${HELM_ARGS:-}" =~ [^[:space:]] ]]; then
  read -r -a extra <<<"${HELM_ARGS}"
fi

printf 'deploying sensor tag %s\n' "$TAG"
helm_cmd=(
  helm upgrade --install sensor "$chart"
  -n sensor
  --create-namespace
  --atomic
  --wait
  --timeout 3m
  --set "image.api.repository=${prefix}/sensor-gateway"
  --set-string "image.api.tag=${TAG}"
  --set "image.web.repository=${prefix}/sensor-web"
  --set-string "image.web.tag=${TAG}"
)
if ((${#extra[@]} > 0)); then
  helm_cmd+=("${extra[@]}")
fi
"${helm_cmd[@]}"

# Число ревизий релиза sensor. Пустой вывод, битый JSON, не-список и ошибка helm
# считаются нулём: set -e не должен оборвать скрипт до uninstall/rollback.
revision_count() {
  local raw count
  raw="$(helm history sensor -n sensor -o json 2>/dev/null || true)"
  count="$(
    printf '%s' "${raw}" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print(0)
    raise SystemExit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print(0)
    raise SystemExit(0)
print(len(data) if isinstance(data, list) else 0)
' 2>/dev/null || true
  )"
  if [[ ! "${count}" =~ ^[0-9]+$ ]]; then
    count=0
  fi
  printf '%s\n' "${count}"
}

rollback_or_uninstall() {
  local revs
  revs="$(revision_count)"
  if [[ "${revs}" -le 1 ]]; then
    # Нет ревизий или одна: предыдущей ревизии нет, удаляем релиз.
    printf 'smoke failed on first install (%s revision(s)); helm uninstall sensor -n sensor\n' "${revs}" >&2
    if ! helm uninstall sensor -n sensor --wait; then
      printf 'error: helm uninstall sensor -n sensor --wait failed\n' >&2
      exit 1
    fi
  else
    printf 'smoke failed (%s revisions); helm rollback sensor 0 -n sensor --wait\n' "${revs}" >&2
    # Ревизия 0 = предыдущая.
    if ! helm rollback sensor 0 -n sensor --wait; then
      printf 'error: helm rollback sensor 0 -n sensor --wait failed\n' >&2
      exit 1
    fi
  fi
}

# Stable smoke must not inherit a canary pin from the caller.
# "X-Canary: never" pins the stable smoke to stable pods while a canary ingress exists,
# so the release under test is really the stable one.
if ! X_CANARY=never "${ROOT}/scripts/smoke.sh"; then
  rollback_or_uninstall
  exit 1
fi

printf 'PASS deploy sensor %s\n' "$TAG"

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
  --set "image.api.tag=${TAG}"
  --set "image.web.repository=${prefix}/sensor-web"
  --set "image.web.tag=${TAG}"
)
if ((${#extra[@]} > 0)); then
  helm_cmd+=("${extra[@]}")
fi
"${helm_cmd[@]}"

# Stable smoke must not inherit a canary pin from the caller.
# "X-Canary: never" pins the stable smoke to stable pods while a canary ingress exists,
# so the release under test is really the stable one.
if ! X_CANARY=never "${ROOT}/scripts/smoke.sh"; then
  revs="$(helm history sensor -n sensor -o json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  if [[ "${revs}" -le 1 ]]; then
    # Первая установка: откатываться некуда, удаляем релиз целиком.
    printf 'smoke failed on first install; helm uninstall sensor -n sensor\n' >&2
    helm uninstall sensor -n sensor --wait || true
  else
    printf 'smoke failed; helm rollback sensor 0 -n sensor --wait\n' >&2
    # Ревизия 0 = предыдущая.
    helm rollback sensor 0 -n sensor --wait || true
  fi
  exit 1
fi

printf 'PASS deploy sensor %s\n' "$TAG"

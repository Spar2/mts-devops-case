#!/usr/bin/env bash
# Shift TAG onto the canary release in weight steps, then promote it.
#
# Usage: canary.sh TAG [WEIGHT ...]
#   Default weights: 10 50
#   IMAGE_REPO_PREFIX and HELM_ARGS are the same as deploy.sh.
#
# Each step installs release sensor-canary with track=canary,
# canary.enabled=true and canary.weight=W, then smoke-tests with
# header "X-Canary: always". The chart ingress annotation
# nginx.ingress.kubernetes.io/canary-by-header: X-Canary sends that
# request to the canary pods. POST /api/v1/service/probe 200 is the
# Prometheus-free signal (smoke.sh).
# Success: deploy.sh TAG, then helm uninstall sensor-canary.
# Failure: uninstall sensor-canary and exit 1.

set -euo pipefail

usage() {
  printf 'usage: %s TAG [WEIGHT ...]\n' "${0##*/}" >&2
  printf '  default weights: 10 50\n' >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

TAG=$1
shift
if [[ ! "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  printf 'TAG is not a valid image tag: %s\n' "$TAG" >&2
  exit 2
fi

weights=()
if [[ $# -eq 0 ]]; then
  weights=(10 50)
else
  for raw in "$@"; do
    read -r -a parts <<<"$raw"
    for part in "${parts[@]}"; do
      if [[ -n "$part" ]]; then
        weights+=("$part")
      fi
    done
  done
fi

if [[ ${#weights[@]} -eq 0 ]]; then
  usage
  exit 2
fi

for weight in "${weights[@]}"; do
  if [[ ! "$weight" =~ ^([0-9]|[1-9][0-9]|100)$ ]]; then
    printf 'weight must be an integer from 0 to 100: %s\n' "$weight" >&2
    exit 2
  fi
done

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

abort_canary() {
  printf 'uninstalling sensor-canary\n' >&2
  # --atomic may already have removed a failed first install.
  helm uninstall sensor-canary -n sensor --wait --timeout 3m --ignore-not-found || true
  exit 1
}

install_weight() {
  local weight=$1
  local -a cmd
  printf 'installing sensor-canary tag %s weight %s\n' "$TAG" "$weight"
  cmd=(
    helm upgrade --install sensor-canary "$chart"
    -n sensor
    --create-namespace
    --atomic
    --wait
    --timeout 3m
    --set "image.api.repository=${prefix}/sensor-gateway"
    --set "image.api.tag=${TAG}"
    --set "image.web.repository=${prefix}/sensor-web"
    --set "image.web.tag=${TAG}"
    --set track=canary
    --set canary.enabled=true
  )
  if ((${#extra[@]} > 0)); then
    cmd+=("${extra[@]}")
  fi
  # This step's weight wins over a weight buried in HELM_ARGS.
  cmd+=(--set "canary.weight=${weight}")
  "${cmd[@]}"
}

for weight in "${weights[@]}"; do
  if ! install_weight "$weight"; then
    printf 'FAIL canary weight %s: helm upgrade failed\n' "$weight" >&2
    abort_canary
  fi
  # Header value "always" is what nginx ingress routes to the canary.
  if ! X_CANARY=always "${ROOT}/scripts/smoke.sh"; then
    printf 'FAIL canary weight %s: smoke failed\n' "$weight" >&2
    abort_canary
  fi
  printf 'PASS canary weight %s\n' "$weight"
done

printf 'promoting %s to stable release sensor\n' "$TAG"
if ! "${ROOT}/scripts/deploy.sh" "$TAG"; then
  printf 'FAIL promote %s\n' "$TAG" >&2
  abort_canary
fi

helm uninstall sensor-canary -n sensor --wait --timeout 3m
printf 'PASS canary promoted %s\n' "$TAG"

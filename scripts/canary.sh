#!/usr/bin/env bash
# Shift TAG onto sensor-canary in weight steps, then promote it.
#
# Usage: canary.sh TAG [WEIGHT ...]
#   Default weights: 10 50 100
#   IMAGE_REPO_PREFIX  registry prefix, default ghcr.io/spar2/mts-devops-case
#   CANARY_HELM_ARGS   extra helm arguments, split on whitespace and appended
#                      to the sensor-canary install only (not the promote)
#   PROM_URL           Prometheus base URL, default http://127.0.0.1:9090
#   ANALYSIS_WAIT_S    seconds to wait after canary load before the metric
#                      queries, default 75
#   BASE_URL           same as smoke.sh; INGRESS_PORT used when it is unset
#
# Each step installs release sensor-canary (track=canary, canary.enabled=true,
# canary.weight=W). Analysis then requires both gates:
#   1. scripts/smoke.sh with X_CANARY=always
#   2. Prometheus: wait up to 180 s for the canary target, send 10 requests with
#      "X-Canary: always" through ingress-nginx, wait ANALYSIS_WAIT_S, then:
#        min(up{namespace="sensor",service="sensor-canary-api"}) == 1
#        canary request rate from nginx_ingress_controller_requests
#          {exported_namespace="sensor",canary=~".+sensor-canary.+"} > 0
#        share of 5xx among those requests < 0.05
#      Prometheus unreachable at PROM_URL also rolls the canary back.
# A failed install or gate sets weight 0, uninstalls sensor-canary, prints
# "ROLLBACK canary: <reason>", and does not change release sensor.
# Success: scripts/deploy.sh TAG, then uninstall sensor-canary.

set -euo pipefail

usage() {
  printf 'usage: %s TAG [WEIGHT ...]\n' "${0##*/}" >&2
  printf '  default weights: 10 50 100\n' >&2
}

now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

step() {
  printf '%s %s\n' "$(now)" "$*"
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
  weights=(10 50 100)
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

analysis_wait="${ANALYSIS_WAIT_S:-75}"
if [[ ! "$analysis_wait" =~ ^[0-9]+$ ]]; then
  printf 'ANALYSIS_WAIT_S must be a non-negative integer\n' >&2
  exit 2
fi

prom_url="${PROM_URL:-http://127.0.0.1:9090}"
prom_url="${prom_url%/}"
if [[ ! "$prom_url" =~ ^https?://[^[:space:]]+$ ]]; then
  printf 'PROM_URL must be an http(s) URL without spaces: %s\n' "$prom_url" >&2
  exit 2
fi

if [[ -n "${BASE_URL:-}" ]]; then
  base_url="${BASE_URL%/}"
else
  ingress_port="${INGRESS_PORT:-80}"
  if [[ ! "$ingress_port" =~ ^[0-9]+$ ]] || ((10#$ingress_port < 1 || 10#$ingress_port > 65535)); then
    printf 'INGRESS_PORT must be a TCP port\n' >&2
    exit 2
  fi
  base_url="http://sensor.localtest.me:${ingress_port}"
fi
if [[ ! "$base_url" =~ ^https?://[^[:space:]]+$ ]]; then
  printf 'BASE_URL must be an http(s) URL without spaces: %s\n' "$base_url" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="${ROOT}/deploy/helm/sensor-gateway"

# Опционально: если локальная LLM доступна (make llm-up), вывод пишется ещё и в лог, чтобы при откате
# scripts/llm-explain-hook.sh объяснил причину. Best-effort: на откат и код выхода не влияет. LLM_EXPLAIN=0 — выключить.
canary_log=""
if [[ "${LLM_EXPLAIN:-auto}" != 0 ]] && curl -sf -m 2 "${LLM_URL:-http://127.0.0.1:8090}/health" >/dev/null 2>&1; then
  canary_log="$(mktemp)"
  exec > >(tee -a "$canary_log") 2>&1
fi
prefix="${IMAGE_REPO_PREFIX:-ghcr.io/spar2/mts-devops-case}"
prefix="${prefix%/}"
if [[ ! "$prefix" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
  printf 'IMAGE_REPO_PREFIX is not a repository prefix: %s\n' "$prefix" >&2
  exit 2
fi

canary_extra=()
if [[ "${CANARY_HELM_ARGS:-}" =~ [^[:space:]] ]]; then
  read -r -a canary_extra <<<"${CANARY_HELM_ARGS}"
fi

command -v helm >/dev/null 2>&1 || {
  printf 'helm is required\n' >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  printf 'curl is required\n' >&2
  exit 1
}

# Drain canary traffic, delete the release, and stop. Release sensor is not
# upgraded, rolled back, or uninstalled here.
rollback_canary() {
  local reason=$1
  local -a cmd
  step "setting canary weight 0"
  cmd=(
    helm upgrade sensor-canary "$chart"
    -n sensor
    --reuse-values
    --wait
    --timeout 3m
    --set canary.weight=0
  )
  "${cmd[@]}" || true
  step "helm uninstall sensor-canary"
  helm uninstall sensor-canary -n sensor --wait --timeout 3m --ignore-not-found || true
  printf '%s ROLLBACK canary: %s\n' "$(now)" "$reason"
  if [[ -n "$canary_log" ]]; then
    "${ROOT}/scripts/llm-explain-hook.sh" "$reason" "$canary_log" || true
    rm -f -- "$canary_log"
  fi
  exit 1
}

install_canary() {
  local weight=$1
  local -a cmd
  step "installing sensor-canary tag ${TAG} weight ${weight}"
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
    --set "canary.weight=${weight}"
  )
  if ((${#canary_extra[@]} > 0)); then
    cmd+=("${canary_extra[@]}")
  fi
  "${cmd[@]}" || return 1
  # Без готовых подов canary ingress-nginx молча отдаёт трафик stable, и smoke
  # проверил бы не тот релиз: явно ждём оба Deployment canary.
  kubectl -n sensor rollout status deployment/sensor-canary-api --timeout=120s || return 1
  kubectl -n sensor rollout status deployment/sensor-canary-web --timeout=120s || return 1
}

# 0 when ${PROM_URL}/-/ready answers any HTTP status. Connection failure is
# unreachable: metric_gate then rolls the canary back.
prom_reachable() {
  local status
  status="$(
    curl --silent --globoff --connect-timeout 3 --max-time 5 \
      -o /dev/null -w '%{http_code}' \
      "${prom_url}/-/ready" || true
  )"
  [[ "$status" =~ ^[1-9][0-9][0-9]$ ]]
}

# Print the first instant-query sample on stdout.
# Return 1 when the vector is empty, 2 when Prometheus did not return success.
# Runs inside a command substitution: logs go to stderr only.
prom_sample() {
  local query=$1
  local body raw status
  local value_re
  body="$(mktemp)"
  status="$(
    curl --silent --show-error --globoff --connect-timeout 3 --max-time 15 \
      -o "$body" -w '%{http_code}' \
      --get --data-urlencode "query=${query}" \
      "${prom_url}/api/v1/query" || true
  )"
  raw="$(cat "$body" 2>/dev/null || true)"
  rm -f -- "$body"
  if [[ "$status" != "200" ]]; then
    printf '%s prometheus query failed HTTP %s: %s\n' "$(now)" "$status" "$query" >&2
    return 2
  fi
  if ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"success"' <<<"$raw"; then
    printf '%s prometheus query status is not success: %s\n' "$(now)" "$query" >&2
    return 2
  fi
  # "value":[<timestamp>,"<sample>"] — one capture, the sample string.
  value_re='"value"[[:space:]]*:[[:space:]]*\[[[:space:]]*[^,]+[[:space:]]*,[[:space:]]*"([^"]+)"'
  if [[ "$raw" =~ $value_re ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

metric_is_one() {
  LC_ALL=C awk -v v="$1" 'BEGIN {
    if (v !~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) exit 1
    exit !(v + 0 == 1)
  }'
}

metric_positive() {
  LC_ALL=C awk -v v="$1" 'BEGIN {
    if (v !~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) exit 1
    exit !(v + 0 > 0)
  }'
}

# Ingress sends X-Canary: always to the canary web pod. /ready is proxied to
# the API, so these hits move http_requests_total on sensor-canary-api.
generate_canary_load() {
  local i
  step "sending 10 requests to ${base_url}/ready with X-Canary: always"
  for ((i = 1; i <= 10; i++)); do
    curl --silent --show-error --globoff --connect-timeout 3 --max-time 10 \
      --output /dev/null \
      -H 'X-Canary: always' \
      "${base_url}/ready" || true
  done
}

# prom_sample runs in a command substitution. rollback_canary calls exit, so it
# has to run in this shell; exit inside $(...) would only leave the subshell
# and the ROLLBACK line would be captured instead of printed.
check_sample() {
  local query=$1
  local weight=$2
  sample_rc=0
  sample_value="$(prom_sample "$query")" || sample_rc=$?
  if [[ "$sample_rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$sample_rc" -eq 2 ]]; then
    rollback_canary "prometheus query failed at weight ${weight}: ${query}"
  fi
  rollback_canary "prometheus returned no sample at weight ${weight}: ${query}"
}

metric_gate() {
  local weight=$1
  local q_up q_rate q_err
  q_up='min(up{namespace="sensor",service="sensor-canary-api"})'
  # Трафик и ошибки считаем по ingress-nginx (canary-Ingress), а не по метрикам API:
  # пробы kubelet и scrape в эти ряды не попадают.
  q_rate='sum(rate(nginx_ingress_controller_requests{exported_namespace="sensor",canary=~".+sensor-canary.+"}[2m]))'
  q_err='(sum(rate(nginx_ingress_controller_requests{exported_namespace="sensor",canary=~".+sensor-canary.+",status=~"5.."}[2m])) or vector(0)) / sum(rate(nginx_ingress_controller_requests{exported_namespace="sensor",canary=~".+sensor-canary.+"}[2m]))'

  if ! prom_reachable; then
    rollback_canary "prometheus unreachable at ${prom_url}; metric gate cannot run"
  fi

  # Новый ServiceMonitor canary Prometheus подхватывает не сразу (operator + reload):
  # ждём появления target до 180 с, иначе это откат.
  local t0=$SECONDS
  until prom_sample "$q_up" >/dev/null 2>&1; do
    if (( SECONDS - t0 > 180 )); then
      rollback_canary "prometheus has no target sensor-canary-api after 180s at weight ${weight}"
    fi
    sleep 5
  done
  step "prometheus sees sensor-canary-api after $((SECONDS - t0))s"
  generate_canary_load
  step "waiting ${analysis_wait}s before prometheus analysis"
  sleep "$analysis_wait"

  step "query ${q_up}"
  check_sample "$q_up" "$weight"
  step "min(up sensor-canary-api)=${sample_value}"
  if ! metric_is_one "$sample_value"; then
    rollback_canary "${q_up}=${sample_value} at weight ${weight}, want 1"
  fi

  step "query ${q_rate}"
  check_sample "$q_rate" "$weight"
  step "canary ingress request rate=${sample_value}/s"
  if ! metric_positive "$sample_value"; then
    rollback_canary "${q_rate}=${sample_value} at weight ${weight}, want > 0"
  fi

  step "query ${q_err}"
  check_sample "$q_err" "$weight"
  step "canary 5xx ratio=${sample_value}"
  if ! awk -v v="$sample_value" 'BEGIN { exit !(v + 0 < 0.05) }'; then
    rollback_canary "canary 5xx ratio ${sample_value} at weight ${weight}, want < 0.05"
  fi
  step "PASS metrics at weight ${weight}"
}

step "canary ${TAG} weights: ${weights[*]}"
if ((${#canary_extra[@]} > 0)); then
  step "CANARY_HELM_ARGS: ${canary_extra[*]}"
fi

for weight in "${weights[@]}"; do
  if ! install_canary "$weight"; then
    rollback_canary "helm upgrade failed at weight ${weight}"
  fi
  step "smoke X-Canary: always at weight ${weight}"
  if ! X_CANARY=always "${ROOT}/scripts/smoke.sh"; then
    rollback_canary "smoke failed at weight ${weight}"
  fi
  step "PASS smoke at weight ${weight}"
  metric_gate "$weight"
  step "PASS canary weight ${weight}"
done

step "promoting ${TAG} to stable via deploy.sh"
if ! "${ROOT}/scripts/deploy.sh" "$TAG"; then
  rollback_canary "promote via deploy.sh failed for ${TAG}"
fi

step "uninstalling sensor-canary after promote"
helm uninstall sensor-canary -n sensor --wait --timeout 3m
step "PASS canary promoted ${TAG}"

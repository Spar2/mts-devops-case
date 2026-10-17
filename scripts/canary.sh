#!/usr/bin/env bash
# Shift TAG onto sensor-canary in weight steps, then promote it.
#
# Usage: canary.sh TAG [WEIGHT ...]
#   Default weights: 10 50 100
#   IMAGE_REPO_PREFIX   registry prefix, default ghcr.io/spar2/mts-devops-case
#   CANARY_HELM_ARGS    extra helm arguments, split on whitespace and appended
#                       to the sensor-canary install only (not the promote)
#   PROM_URL            Prometheus base URL, default http://127.0.0.1:9090
#   ANALYSIS_WAIT_S     seconds to wait after canary load before the metric
#                       queries, default 75
#   BASE_URL            same as smoke.sh; INGRESS_PORT used when it is unset
#   WEIGHT_SAMPLE_N     unweighted /ready requests per step, default 100
#   WEIGHT_SETTLE_S     seconds after smoke before the weight-sample baseline,
#                       so X-Canary traffic is already in the ingress counter.
#                       Default 20 (ingress-nginx scrape is 15s).
#   WEIGHT_METRIC_WAIT_S  seconds to wait for that counter to move, default 60
#   CANARY_SELF_TEST=1  check finite numbers, weight bounds, the HTTP 200
#                       share, the 5xx ratio (401 is not a 5xx) and rollback
#                       error lines, then exit
#
# make k8s-canary passes CANARY_TAG (default <stable-sha>-canary), not TAG.
# The chart sets APP_VERSION to the image tag. GET /ready returns it as JSON
# "version" and as X-App-Version.
#
# Each step installs release sensor-canary (track=canary, canary.enabled=true,
# canary.weight=W) and waits until ingress-nginx shows that weight. Then:
#   1. scripts/smoke.sh with X_CANARY=always and EXPECT_VERSION=TAG
#   2. WEIGHT_SAMPLE_N rounds with no X-Canary header and no cookie, each round
#      hitting /ready, / and /api/v1/service. Without a cookie /api/v1/service
#      is 401, and 401 is not a 5xx. The version share uses only HTTP 200
#      /ready responses (integer percent, hits*100/http_ok): 10 → 2–25,
#      50 → 30–70, 100 → 100. Another weight w in 1..99 →
#      max(1, w-20)..min(99, w+20). 0 → 0. At weight 100 a /ready response
#      that is not HTTP 200 rolls back on its own; it is not folded into the
#      percent.
#   3. Ingress-nginx counter delta around that same sample: canary label
#      =~ .+sensor-canary.+ over all requests in namespace sensor. Same bands,
#      except weight 100 is 95–100 so one stray request does not fail the step.
#      Header traffic from the smoke is outside this delta.
#   4. Prometheus, after 10 requests with X-Canary: always and ANALYSIS_WAIT_S:
#        min(up{namespace="sensor",service="sensor-canary-api"}) == 1
#          (only if the target appears within 120s)
#        canary request rate > 0
#      Those 10 requests are not the 5xx share. The share is HTTP 5xx among
#      the unheadered sample in step 2, divided by every HTTP status in that
#      sample (401 stays in the denominator). It must be >= 0 and < 0.05.
#      NaN, +Inf, -Inf, empty and non-numeric Prometheus samples roll back.
#      mawk turns NaN and Inf into 0, so a bare numeric compare would accept
#      them. Prometheus unreachable at PROM_URL also rolls the canary back.
# A failed install or gate sets weight 0, uninstalls sensor-canary and prints
# "ROLLBACK canary: <reason>". If setting weight 0 or the uninstall fails, the
# script prints "error:" and still finishes every remaining rollback step.
# The exit code is non-zero. Release sensor is left as it was, except when
# promote's deploy.sh already moved stable to TAG and the rollout after that
# did not finish: then the rollback also runs `helm rollback sensor 0`.
# Success: deploy.sh moves stable to TAG, both rollouts finish, canary weight
# goes to 0, ingress-nginx must show that weight, then sensor-canary is removed.

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

# mawk (Ubuntu /usr/bin/awk) converts NaN and Inf to 0. Reject the strings
# before any numeric compare, and reject values that become Inf (1e309).
metric_finite() {
  LC_ALL=C awk -v v="$1" 'BEGIN {
    if (v == "") exit 1
    s = tolower(v)
    if (s ~ /nan/ || s ~ /inf/) exit 1
    if (v !~ /^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) exit 1
    x = v + 0
    xs = tolower(sprintf("%s", x))
    if (xs ~ /nan/ || xs ~ /inf/) exit 1
    exit 0
  }'
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

# True when v is >= 0 and < limit. Caller has already required a finite v.
metric_below() {
  LC_ALL=C awk -v v="$1" -v lim="$2" 'BEGIN {
    x = v + 0
    exit !((x >= 0) && (x < lim + 0))
  }'
}

# Inclusive integer percent band for a canary weight.
weight_bounds() {
  local w=$1
  local lo hi
  case "$w" in
    0) lo=0; hi=0 ;;
    10) lo=2; hi=25 ;;
    50) lo=30; hi=70 ;;
    100) lo=100; hi=100 ;;
    *)
      lo=$((w - 20))
      hi=$((w + 20))
      if ((lo < 1)); then
        lo=1
      fi
      if ((hi > 99)); then
        hi=99
      fi
      ;;
  esac
  printf '%s %s\n' "$lo" "$hi"
}

# Ingress-counter band. Weight 100 is not exact: one request outside the
# sample must not fail the step.
ingress_share_bounds() {
  local w=$1
  if [[ "$w" == 100 ]]; then
    printf '95 100\n'
    return 0
  fi
  weight_bounds "$w"
}

# Integer percent of canary hits among HTTP 200 responses. Exit 1 when there
# is no HTTP 200 or hits exceed that count.
response_share_percent() {
  local hits=$1
  local http_ok=$2
  if [[ ! "$hits" =~ ^[0-9]+$ || ! "$http_ok" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if ((http_ok <= 0 || hits > http_ok)); then
    return 1
  fi
  printf '%s\n' "$((hits * 100 / http_ok))"
}

# "<5xx_count> <http_count> <ratio>". 401 and any other non-5xx code are only
# in http_count. Exit 1 on an empty list or a non-HTTP status (including 000).
http_5xx_summary() {
  local status five=0 total=0 ratio
  if [[ $# -eq 0 ]]; then
    return 1
  fi
  for status in "$@"; do
    if [[ ! "$status" =~ ^[1-9][0-9][0-9]$ ]]; then
      return 1
    fi
    total=$((total + 1))
    if [[ "$status" =~ ^5[0-9][0-9]$ ]]; then
      five=$((five + 1))
    fi
  done
  ratio="$(LC_ALL=C awk -v f="$five" -v t="$total" 'BEGIN { printf "%.6f", f / t }')"
  printf '%s %s %s\n' "$five" "$total" "$ratio"
}

# Record a rollback step that failed. Prints "error:" and returns 0 so the
# caller can keep going. rollback_canary still exits non-zero.
note_rollback_failure() {
  printf 'error: %s failed\n' "$1" >&2
  rollback_failed=1
}

counter_delta() {
  LC_ALL=C awk -v b="$1" -v a="$2" 'BEGIN { printf "%.6f", (a + 0) - (b + 0) }'
}

# Nearest integer percent. Exit 1 when the total did not grow or canary went
# backwards (counter reset).
metric_share_percent() {
  LC_ALL=C awk -v bc="$1" -v ac="$2" -v ba="$3" -v aa="$4" 'BEGIN {
    dc = (ac + 0) - (bc + 0)
    dt = (aa + 0) - (ba + 0)
    if (dt <= 0 || dc < 0) exit 1
    printf "%d", int(dc * 100 / dt + 0.5)
  }'
}

header_app_version() {
  awk 'tolower($1) == "x-app-version:" { gsub(/\r/, "", $2); print $2; exit }' "$1"
}

body_app_version() {
  awk '
    match($0, /"version"[[:space:]]*:[[:space:]]*"[^"]*"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^"version"[[:space:]]*:[[:space:]]*"/, "", s)
      sub(/"$/, "", s)
      print s
      exit
    }
  ' "$1"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="${ROOT}/deploy/helm/sensor-gateway"
canary_log=""
sample_value=""
sample_rc=0
# 5xx ratio of the latest unheadered weight sample. metric_gate reads these.
sample_5xx_hits=0
sample_5xx_total=0
sample_5xx_ratio=""
# 1 only after deploy.sh has moved stable to TAG and rollout is not confirmed.
stable_needs_rollback=0
rollback_failed=0

# Drain canary, and roll stable back when promote already moved it and the
# rollout did not finish. Keep going after a failed step. Always exit 1.
rollback_canary() {
  local reason=$1
  rollback_failed=0
  if [[ "$stable_needs_rollback" == 1 ]]; then
    step "helm rollback sensor 0 after stable rollout of ${TAG} did not finish"
    if ! helm rollback sensor 0 -n sensor --wait --timeout 3m; then
      note_rollback_failure "helm rollback sensor 0 -n sensor --wait --timeout 3m"
    fi
  fi
  if ! set_canary_weight 0; then
    note_rollback_failure "set canary weight 0"
  fi
  step "helm uninstall sensor-canary"
  if ! helm uninstall sensor-canary -n sensor --wait --timeout 3m --ignore-not-found; then
    note_rollback_failure "helm uninstall sensor-canary -n sensor --wait --timeout 3m --ignore-not-found"
  fi
  printf '%s ROLLBACK canary: %s\n' "$(now)" "$reason"
  if [[ -n "$canary_log" ]]; then
    "${ROOT}/scripts/llm-explain-hook.sh" "$reason" "$canary_log" || true
    rm -f -- "$canary_log"
  fi
  exit 1
}

set_canary_weight() {
  local weight=$1
  step "setting canary weight ${weight}"
  helm upgrade sensor-canary "$chart" \
    -n sensor \
    --reuse-values \
    --wait \
    --timeout 3m \
    --set "canary.weight=${weight}"
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
    --set-string "image.api.tag=${TAG}"
    --set "image.web.repository=${prefix}/sensor-web"
    --set-string "image.web.tag=${TAG}"
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
  wait_ingress_backend
}

# ingress-nginx применяет новый canary-Ingress с задержкой; до этого X-Canary: always
# уходит в stable. Ждём (до 90 с), пока у контроллера появится backend canary с endpoint
# и пока stable backend не сошлётся на него в alternativeBackends: без этой ссылки
# балансировщик ещё не делит трафик и smoke попадает в stable.
wait_ingress_backend() {
  local i be=sensor-sensor-canary-web-http stable_be=sensor-sensor-web-http
  for ((i = 0; i < 45; i++)); do
    if kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- /dbg backends get "$be" 2>/dev/null \
        | grep -q '"address"' \
      && kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- /dbg backends get "$stable_be" 2>/dev/null \
        | tr -d ' \n' | grep -q "\"alternativeBackends\":\[[^]]*\"${be}\""; then
      step "ingress-nginx backend ${be} has endpoints and is linked from ${stable_be}"
      return 0
    fi
    sleep 2
  done
  step "ingress-nginx backend ${be} is not ready or not linked from ${stable_be} after 90s"
  return 1
}

# Live canary weight from ingress-nginx (trafficShapingPolicy.weight on the
# canary backend). Prints the integer. Exit 2 when the backend JSON is unusable.
ingress_canary_weight() {
  local raw
  raw="$(kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- /dbg backends get "$1" 2>/dev/null || true)"
  printf '%s' "$raw" | python3 -c '
import json
import sys
raw = sys.stdin.read()
start = raw.find("{")
end = raw.rfind("}")
if start < 0 or end < start:
    raise SystemExit(2)
try:
    data = json.loads(raw[start:end + 1])
except json.JSONDecodeError:
    raise SystemExit(2)
policy = data.get("trafficShapingPolicy") or {}
weight = policy.get("weight")
if isinstance(weight, bool) or not isinstance(weight, int):
    raise SystemExit(2)
sys.stdout.write(str(weight))
'
}

# Poll until the canary backend weight equals $1. Same 90s budget as
# wait_ingress_backend: helm --wait does not wait for the controller reload.
wait_ingress_canary_weight() {
  local want=$1
  local be=sensor-sensor-canary-web-http
  local i seen="<none>" seen_now
  for ((i = 0; i < 45; i++)); do
    if seen_now="$(ingress_canary_weight "$be")"; then
      seen=$seen_now
      if [[ "$seen" == "$want" ]]; then
        step "ingress-nginx backend ${be} weight is ${want}"
        return 0
      fi
    fi
    sleep 2
  done
  step "ingress-nginx backend ${be} weight is ${seen}, want ${want}, after 90s"
  return 1
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

# Sets sample_value to a finite sample. empty_ok=1 maps an empty vector to 0.
# Otherwise an empty vector, a failed query, or a non-finite sample rolls back.
# Do not call this inside a command substitution: rollback_canary exits.
load_finite_sample() {
  local query=$1
  local weight=$2
  local empty_ok=${3:-0}
  local waited=0
  sample_rc=0
  sample_value="$(prom_sample "$query")" || sample_rc=$?
  # Пустой вектор сразу после make up: Prometheus ещё не снял первый scrape
  # ingress-nginx. Ждём до PROM_EMPTY_WAIT_S (60 с), потом откат. NaN/Inf не ждём.
  while [[ "$sample_rc" -eq 1 && "$empty_ok" -ne 1 && "$waited" -lt "${PROM_EMPTY_WAIT_S:-60}" ]]; do
    sleep 5
    waited=$((waited + 5))
    sample_rc=0
    sample_value="$(prom_sample "$query")" || sample_rc=$?
  done
  if [[ "$sample_rc" -eq 1 && "$empty_ok" -eq 1 ]]; then
    sample_value=0
    sample_rc=0
    return 0
  fi
  if [[ "$sample_rc" -eq 2 ]]; then
    rollback_canary "prometheus query failed at weight ${weight}: ${query}"
  fi
  if [[ "$sample_rc" -ne 0 ]]; then
    rollback_canary "prometheus returned no sample at weight ${weight}: ${query}"
  fi
  if ! metric_finite "$sample_value"; then
    rollback_canary "prometheus sample is not a finite number (${sample_value}) at weight ${weight}: ${query}"
  fi
}

# These 10 requests only keep the canary rate query above zero. The 5xx share
# is the unheadered weight sample, not this burst.
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

# Unheadered requests on several paths, then the ingress counter delta.
weight_gate() {
  local weight=$1
  local lo hi ilo ihi n hits http_ok i status path sent
  local ready_non200 ready_bad transport_fail transport_path
  local header_version body_version pct pct_rc summary summary_rc
  local q_all q_canary
  local before_all before_canary after_all after_canary
  local total_delta share_pct share_rc
  local work hdr body deadline
  local -a sample_paths statuses
  sample_5xx_hits=0
  sample_5xx_total=0
  sample_5xx_ratio=""
  read -r lo hi < <(weight_bounds "$weight")
  read -r ilo ihi < <(ingress_share_bounds "$weight")
  n=$weight_sample_n
  sample_paths=(/ready / /api/v1/service)
  sent=$((n * ${#sample_paths[@]}))
  q_all='sum(nginx_ingress_controller_requests{exported_namespace="sensor"})'
  q_canary='sum(nginx_ingress_controller_requests{exported_namespace="sensor",canary=~".+sensor-canary.+"}) or vector(0)'

  if ! prom_reachable; then
    rollback_canary "prometheus unreachable at ${prom_url}; weight gate cannot run"
  fi

  # Smoke with X-Canary: always is canary traffic. Wait one scrape so it sits
  # in the baseline and does not inflate the weight share.
  if ((weight_settle_s > 0)); then
    step "waiting ${weight_settle_s}s so header smoke is in the ingress counter before the weight sample"
    sleep "$weight_settle_s"
  fi
  load_finite_sample "$q_all" "$weight"
  before_all=$sample_value
  load_finite_sample "$q_canary" "$weight" 1
  before_canary=$sample_value

  work="$(mktemp -d)"
  hdr="${work}/headers"
  body="${work}/body"
  hits=0
  http_ok=0
  ready_non200=0
  ready_bad=""
  transport_fail=0
  transport_path=""
  statuses=()
  # Same series for the version share and the 5xx ratio. No X-Canary, no cookie.
  step "sending ${n} requests without X-Canary to /ready, / and /api/v1/service (HTTP 200 /ready share want ${lo}-${hi}% version ${TAG})"
  for ((i = 1; i <= n; i++)); do
    for path in "${sample_paths[@]}"; do
      status="$(
        curl --silent --globoff --connect-timeout 3 --max-time 10 \
          -D "$hdr" -o "$body" -w '%{http_code}' \
          "${base_url}${path}" || true
      )"
      if [[ ! "$status" =~ ^[0-9]{3}$ ]]; then
        status=000
      fi
      statuses+=("$status")
      if [[ "$status" == "000" ]]; then
        transport_fail=$((transport_fail + 1))
        if [[ -z "$transport_path" ]]; then
          transport_path=$path
        fi
        continue
      fi
      if [[ "$path" != /ready ]]; then
        continue
      fi
      if [[ "$status" != "200" ]]; then
        ready_non200=$((ready_non200 + 1))
        if [[ -z "$ready_bad" ]]; then
          ready_bad=$status
        fi
        continue
      fi
      http_ok=$((http_ok + 1))
      header_version="$(header_app_version "$hdr")"
      body_version="$(body_app_version "$body")"
      if [[ "$header_version" == "$TAG" && "$body_version" == "$TAG" ]]; then
        hits=$((hits + 1))
      fi
    done
  done
  rm -rf -- "$work"

  if ((transport_fail > 0)); then
    rollback_canary "weight sample got ${transport_fail} responses with no HTTP status (first ${transport_path}) at weight ${weight}"
  fi
  # Weight 100 used to treat one non-200 as a missed hit and fail the 100% band.
  # Count the version share on HTTP 200 only, and say why the rest failed.
  if [[ "$weight" == 100 && "$ready_non200" -gt 0 ]]; then
    rollback_canary "weight sample /ready got ${ready_non200}/${n} non-200 at weight 100 (first HTTP ${ready_bad}); version share counts only HTTP 200"
  fi

  summary_rc=0
  summary="$(http_5xx_summary "${statuses[@]}")" || summary_rc=$?
  if [[ "$summary_rc" -ne 0 ]]; then
    rollback_canary "unheadered sample statuses are not all HTTP at weight ${weight}"
  fi
  read -r sample_5xx_hits sample_5xx_total sample_5xx_ratio <<<"$summary"

  pct_rc=0
  pct="$(response_share_percent "$hits" "$http_ok")" || pct_rc=$?
  if [[ "$pct_rc" -ne 0 ]]; then
    rollback_canary "weight sample /ready had no HTTP 200 at weight ${weight} (${ready_non200}/${n} non-200)"
  fi
  step "canary version share ${hits}/${http_ok} HTTP 200 = ${pct}% at weight ${weight} (non-200 /ready: ${ready_non200}), want ${lo}-${hi}%"
  if ((pct < lo || pct > hi)); then
    rollback_canary "canary response share ${pct}% (${hits}/${http_ok} HTTP 200) at weight ${weight} outside ${lo}-${hi}%"
  fi

  deadline=$((SECONDS + weight_metric_wait_s))
  while true; do
    load_finite_sample "$q_all" "$weight"
    after_all=$sample_value
    load_finite_sample "$q_canary" "$weight" 1
    after_canary=$sample_value
    total_delta="$(counter_delta "$before_all" "$after_all")"
    if awk -v d="$total_delta" 'BEGIN { exit !(d + 0 < 0) }'; then
      rollback_canary "ingress request counter went backwards (${before_all} -> ${after_all}) at weight ${weight}"
    fi
    if awk -v d="$total_delta" -v need="$sent" 'BEGIN { exit !(d + 0 >= need * 0.8) }'; then
      break
    fi
    if ((SECONDS >= deadline)); then
      rollback_canary "ingress request counter rose by ${total_delta}, want at least 80% of ${sent} weight-sample requests at weight ${weight}"
    fi
    sleep 3
  done

  share_rc=0
  share_pct="$(metric_share_percent "$before_canary" "$after_canary" "$before_all" "$after_all")" || share_rc=$?
  if [[ "$share_rc" -ne 0 ]]; then
    rollback_canary "ingress canary counter delta is not usable at weight ${weight} (canary ${before_canary}->${after_canary}, all ${before_all}->${after_all})"
  fi
  step "ingress canary share ${share_pct}% at weight ${weight} (canary ${before_canary}->${after_canary}, all ${before_all}->${after_all}), want ${ilo}-${ihi}%"
  if ((share_pct < ilo || share_pct > ihi)); then
    rollback_canary "ingress canary share ${share_pct}% at weight ${weight} outside ${ilo}-${ihi}%"
  fi
  step "PASS weight ${weight}"
}

metric_gate() {
  local weight=$1
  local q_up q_rate
  q_up='min(up{namespace="sensor",service="sensor-canary-api"})'
  # Rate is the canary ingress series (kubelet probes are not in it). The 5xx
  # share is the unheadered sample from weight_gate, not this rate.
  q_rate='sum(rate(nginx_ingress_controller_requests{exported_namespace="sensor",canary=~".+sensor-canary.+"}[2m]))'

  if ! prom_reachable; then
    rollback_canary "prometheus unreachable at ${prom_url}; metric gate cannot run"
  fi

  # up и rate — метрики ingress-nginx и ServiceMonitor. Target canary Prometheus
  # подхватывает с задержкой (operator + reload; в e2e на k3s бывало > 180 с),
  # поэтому up проверяется, только если target успел появиться за 120 с.
  # Доля 5xx — коды той же выборки без заголовка (/ready, /, /api/v1/service).
  local t0=$SECONDS have_up=1
  until prom_sample "$q_up" >/dev/null 2>&1; do
    if ((SECONDS - t0 > 120)); then
      have_up=0
      break
    fi
    sleep 5
  done
  generate_canary_load
  step "waiting ${analysis_wait}s before prometheus analysis"
  sleep "$analysis_wait"

  if ((have_up)) || prom_sample "$q_up" >/dev/null 2>&1; then
    step "query ${q_up}"
    load_finite_sample "$q_up" "$weight"
    step "min(up sensor-canary-api)=${sample_value}"
    if ! metric_is_one "$sample_value"; then
      rollback_canary "${q_up}=${sample_value} at weight ${weight}, want 1"
    fi
  else
    step "NOTE target sensor-canary-api not discovered yet; rate uses ingress-nginx, 5xx uses the HTTP sample"
  fi

  step "query ${q_rate}"
  load_finite_sample "$q_rate" "$weight"
  step "canary ingress request rate=${sample_value}/s"
  if ! metric_positive "$sample_value"; then
    rollback_canary "${q_rate}=${sample_value} at weight ${weight}, want > 0"
  fi

  if [[ -z "$sample_5xx_ratio" ]]; then
    rollback_canary "unheadered weight sample did not produce a 5xx ratio at weight ${weight}"
  fi
  step "unheadered sample 5xx ratio=${sample_5xx_ratio} (${sample_5xx_hits}/${sample_5xx_total}) on /ready, /, /api/v1/service without X-Canary (401 is not 5xx)"
  if ! metric_finite "$sample_5xx_ratio"; then
    rollback_canary "unheadered sample 5xx ratio is not finite (${sample_5xx_ratio}) at weight ${weight}"
  fi
  if ! metric_below "$sample_5xx_ratio" 0.05; then
    rollback_canary "unheadered sample 5xx ratio ${sample_5xx_ratio} (${sample_5xx_hits}/${sample_5xx_total}) at weight ${weight}, want >= 0 and < 0.05"
  fi
  step "PASS metrics at weight ${weight}"
}

self_test() {
  local lo hi work hdr body got err five total ratio i
  local -a statuses
  metric_finite 0
  metric_finite 0.04
  metric_finite 0.049
  metric_finite 1
  metric_finite 1.0
  metric_finite 1.5e-3
  metric_finite -1
  metric_finite +1
  metric_finite 1e308

  reject_non_finite() {
    if metric_finite "$1"; then
      printf 'self-test: accepted non-finite [%s]\n' "$1" >&2
      return 1
    fi
  }
  reject_non_finite NaN
  reject_non_finite +Inf
  reject_non_finite -Inf
  reject_non_finite Inf
  reject_non_finite nan
  reject_non_finite ""
  reject_non_finite foo
  reject_non_finite " 1"
  reject_non_finite 1e309

  ratio_ok() {
    metric_finite "$1" && metric_below "$1" 0.05
  }
  ratio_ok 0
  ratio_ok 0.049
  ratio_ok 1e-4
  if ratio_ok NaN || ratio_ok +Inf || ratio_ok -Inf || ratio_ok "" || ratio_ok foo || ratio_ok 0.05 || ratio_ok -0.01; then
    printf 'self-test: 5xx ratio accepted a bad sample\n' >&2
    return 1
  fi
  metric_finite 1 && metric_is_one 1
  if metric_finite NaN && metric_is_one NaN; then
    printf 'self-test: NaN passed the up gate\n' >&2
    return 1
  fi
  if metric_is_one 0 || metric_is_one ""; then
    printf 'self-test: up accepted a value other than 1\n' >&2
    return 1
  fi
  metric_finite 0.1 && metric_positive 0.1
  if metric_finite +Inf && metric_positive +Inf; then
    printf 'self-test: Inf passed the rate gate\n' >&2
    return 1
  fi
  if metric_positive 0 || metric_positive ""; then
    printf 'self-test: rate accepted a non-positive sample\n' >&2
    return 1
  fi
  if metric_finite -1 && metric_positive -1; then
    printf 'self-test: negative rate passed\n' >&2
    return 1
  fi

  assert_bounds() {
    local w="$1" want_lo="$2" want_hi="$3"
    read -r lo hi < <(weight_bounds "$w")
    if [[ "$lo" != "$want_lo" || "$hi" != "$want_hi" ]]; then
      printf 'self-test: weight %s bounds %s-%s, want %s-%s\n' "$w" "$lo" "$hi" "$want_lo" "$want_hi" >&2
      return 1
    fi
  }
  assert_bounds 0 0 0
  assert_bounds 10 2 25
  assert_bounds 50 30 70
  assert_bounds 100 100 100
  assert_bounds 20 1 40
  assert_bounds 90 70 99
  assert_bounds 5 1 25

  assert_ingress_bounds() {
    local w="$1" want_lo="$2" want_hi="$3"
    read -r lo hi < <(ingress_share_bounds "$w")
    if [[ "$lo" != "$want_lo" || "$hi" != "$want_hi" ]]; then
      printf 'self-test: ingress weight %s bounds %s-%s, want %s-%s\n' "$w" "$lo" "$hi" "$want_lo" "$want_hi" >&2
      return 1
    fi
  }
  assert_ingress_bounds 0 0 0
  assert_ingress_bounds 10 2 25
  assert_ingress_bounds 50 30 70
  assert_ingress_bounds 100 95 100
  assert_ingress_bounds 90 70 99

  if [[ "$(response_share_percent 100 100)" != 100 ]] \
    || [[ "$(response_share_percent 49 100)" != 49 ]] \
    || [[ "$(response_share_percent 10 100)" != 10 ]] \
    || [[ "$(response_share_percent 99 99)" != 100 ]]; then
    printf 'self-test: HTTP 200 version share is wrong\n' >&2
    return 1
  fi
  if response_share_percent 0 0 >/dev/null || response_share_percent 1 0 >/dev/null; then
    printf 'self-test: version share accepted an empty HTTP 200 set\n' >&2
    return 1
  fi

  read -r five total ratio < <(http_5xx_summary 401 200 401)
  if [[ "$five" != 0 || "$total" != 3 || "$ratio" != "0.000000" ]] || ! metric_below "$ratio" 0.05; then
    printf 'self-test: 401 counted as 5xx (%s %s %s)\n' "$five" "$total" "$ratio" >&2
    return 1
  fi
  read -r five total ratio < <(http_5xx_summary 500 401 200 200)
  if [[ "$five" != 1 || "$total" != 4 || "$ratio" != "0.250000" ]] || metric_below "$ratio" 0.05; then
    printf 'self-test: 5xx ratio missed a 500 (%s %s %s)\n' "$five" "$total" "$ratio" >&2
    return 1
  fi
  statuses=()
  for ((i = 0; i < 95; i++)); do
    statuses+=(200)
  done
  statuses+=(401 401 401 401 401)
  read -r five total ratio < <(http_5xx_summary "${statuses[@]}")
  if [[ "$five" != 0 || "$total" != 100 || "$ratio" != "0.000000" ]] || ! metric_below "$ratio" 0.05; then
    printf 'self-test: 401-only sample failed the 5xx gate (%s %s %s)\n' "$five" "$total" "$ratio" >&2
    return 1
  fi
  # 4/100 = 0.04 is inside the gate. 5/100 = 0.05 is not.
  statuses=()
  for ((i = 0; i < 96; i++)); do
    statuses+=(200)
  done
  statuses+=(500 500 500 500)
  read -r five total ratio < <(http_5xx_summary "${statuses[@]}")
  if [[ "$five" != 4 || "$total" != 100 || "$ratio" != "0.040000" ]] || ! metric_finite "$ratio" || ! metric_below "$ratio" 0.05; then
    printf 'self-test: 4/100 5xx ratio should pass (%s %s %s)\n' "$five" "$total" "$ratio" >&2
    return 1
  fi
  statuses=()
  for ((i = 0; i < 95; i++)); do
    statuses+=(200)
  done
  statuses+=(500 500 500 500 500)
  read -r five total ratio < <(http_5xx_summary "${statuses[@]}")
  if [[ "$five" != 5 || "$total" != 100 || "$ratio" != "0.050000" ]] || metric_below "$ratio" 0.05; then
    printf 'self-test: 5/100 5xx ratio should fail (%s %s %s)\n' "$five" "$total" "$ratio" >&2
    return 1
  fi
  if http_5xx_summary >/dev/null || http_5xx_summary 000 >/dev/null || http_5xx_summary 200 99 >/dev/null; then
    printf 'self-test: non-HTTP status produced a 5xx ratio\n' >&2
    return 1
  fi

  err="$(mktemp)"
  rollback_failed=0
  note_rollback_failure "set canary weight 0" 2>"$err"
  if [[ "$rollback_failed" -ne 1 ]] || ! grep -qx 'error: set canary weight 0 failed' "$err"; then
    printf 'self-test: weight-0 failure was swallowed\n' >&2
    rm -f -- "$err"
    return 1
  fi
  rollback_failed=0
  note_rollback_failure "helm uninstall sensor-canary -n sensor --wait --timeout 3m --ignore-not-found" 2>"$err"
  if [[ "$rollback_failed" -ne 1 ]] || ! grep -qx 'error: helm uninstall sensor-canary -n sensor --wait --timeout 3m --ignore-not-found failed' "$err"; then
    printf 'self-test: uninstall failure was swallowed\n' >&2
    rm -f -- "$err"
    return 1
  fi
  rollback_failed=0
  note_rollback_failure "helm rollback sensor 0 -n sensor --wait --timeout 3m" 2>"$err"
  if [[ "$rollback_failed" -ne 1 ]] || ! grep -qx 'error: helm rollback sensor 0 -n sensor --wait --timeout 3m failed' "$err"; then
    printf 'self-test: stable rollback failure was swallowed\n' >&2
    rm -f -- "$err"
    return 1
  fi
  rm -f -- "$err"

  assert_share() {
    got="$(metric_share_percent "$1" "$2" "$3" "$4")" || {
      printf 'self-test: share failed for %s\n' "$*" >&2
      return 1
    }
    if [[ "$got" != "$5" ]]; then
      printf 'self-test: share %s, want %s\n' "$got" "$5" >&2
      return 1
    fi
  }
  assert_share 0 100 0 100 100
  assert_share 0 10 0 100 10
  assert_share 0 2 0 100 2
  assert_share 0 25 0 100 25
  assert_share 0 26 0 100 26
  assert_share 0 99 0 100 99
  assert_share 5 15 100 200 10
  assert_share 0 100 0 100.0000001 100
  if metric_share_percent 10 0 0 100 >/dev/null; then
    printf 'self-test: negative canary delta accepted\n' >&2
    return 1
  fi

  work="$(mktemp -d)"
  hdr="${work}/h"
  body="${work}/b"
  printf 'HTTP/1.1 200 OK\r\nX-App-Version: abc1234-canary\r\n\r\n' >"$hdr"
  # Starlette JSONResponse is compact (separators ",", ":"). Spaced JSON is accepted too.
  printf '%s\n' '{"status":"ok","version":"abc1234-canary"}' >"$body"
  if [[ "$(header_app_version "$hdr")" != "abc1234-canary" || "$(body_app_version "$body")" != "abc1234-canary" ]]; then
    printf 'self-test: version parsers missed the compact canary tag\n' >&2
    rm -rf -- "$work"
    return 1
  fi
  printf '%s\n' '{"status": "ok", "version": "abc1234-canary"}' >"$body"
  if [[ "$(body_app_version "$body")" != "abc1234-canary" ]]; then
    printf 'self-test: version parser missed the spaced canary tag\n' >&2
    rm -rf -- "$work"
    return 1
  fi
  printf 'HTTP/1.1 200 OK\r\n\r\n' >"$hdr"
  printf '%s\n' '{"status": "ok"}' >"$body"
  if [[ -n "$(header_app_version "$hdr")" || -n "$(body_app_version "$body")" ]]; then
    printf 'self-test: version parsers invented a version\n' >&2
    rm -rf -- "$work"
    return 1
  fi
  rm -rf -- "$work"
  printf 'canary self-test ok\n'
}

main() {
  local weight raw part parts
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

  weight_sample_n="${WEIGHT_SAMPLE_N:-100}"
  if [[ ! "$weight_sample_n" =~ ^[1-9][0-9]*$ ]] || ((weight_sample_n > 10000)); then
    printf 'WEIGHT_SAMPLE_N must be an integer from 1 to 10000\n' >&2
    exit 2
  fi

  weight_settle_s="${WEIGHT_SETTLE_S:-20}"
  if [[ ! "$weight_settle_s" =~ ^[0-9]+$ ]]; then
    printf 'WEIGHT_SETTLE_S must be a non-negative integer\n' >&2
    exit 2
  fi

  weight_metric_wait_s="${WEIGHT_METRIC_WAIT_S:-60}"
  if [[ ! "$weight_metric_wait_s" =~ ^[0-9]+$ ]]; then
    printf 'WEIGHT_METRIC_WAIT_S must be a non-negative integer\n' >&2
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

  # Опционально: если локальная LLM доступна (make llm-up), вывод пишется ещё и в лог, чтобы при откате
  # scripts/llm-explain-hook.sh объяснил причину. Best-effort: на откат и код выхода не влияет. LLM_EXPLAIN=0 — выключить.
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
  command -v kubectl >/dev/null 2>&1 || {
    printf 'kubectl is required\n' >&2
    exit 1
  }
  command -v python3 >/dev/null 2>&1 || {
    printf 'python3 is required\n' >&2
    exit 1
  }

  step "canary ${TAG} weights: ${weights[*]}"
  if ((${#canary_extra[@]} > 0)); then
    step "CANARY_HELM_ARGS: ${canary_extra[*]}"
  fi

  for weight in "${weights[@]}"; do
    if ! install_canary "$weight"; then
      rollback_canary "helm upgrade failed at weight ${weight}"
    fi
    if ! wait_ingress_canary_weight "$weight"; then
      rollback_canary "ingress-nginx did not apply canary weight ${weight}"
    fi
    step "smoke X-Canary: always at weight ${weight}"
    if ! X_CANARY=always EXPECT_VERSION="$TAG" "${ROOT}/scripts/smoke.sh"; then
      rollback_canary "smoke failed at weight ${weight}"
    fi
    step "PASS smoke at weight ${weight}"
    weight_gate "$weight"
    metric_gate "$weight"
    step "PASS canary weight ${weight}"
  done

  # Stable first, while canary still takes the current weight (100 on the
  # default ladder). Then drop the weight to 0 and only then uninstall, so
  # ingress-nginx is not left sending every request at a backend that is gone.
  # deploy.sh rolls itself back when helm or its smoke fails. Once it
  # returns, stable is on TAG. A rollout that then fails must undo that.
  stable_needs_rollback=0
  step "promoting ${TAG} to stable via deploy.sh"
  if ! "${ROOT}/scripts/deploy.sh" "$TAG"; then
    rollback_canary "promote via deploy.sh failed for ${TAG}"
  fi
  stable_needs_rollback=1
  step "waiting for stable rollout of tag ${TAG}"
  if ! kubectl -n sensor rollout status deployment/sensor-api --timeout=180s; then
    rollback_canary "stable api rollout did not finish for ${TAG}"
  fi
  if ! kubectl -n sensor rollout status deployment/sensor-web --timeout=180s; then
    rollback_canary "stable web rollout did not finish for ${TAG}"
  fi
  stable_needs_rollback=0
  if ! set_canary_weight 0; then
    rollback_canary "failed to set canary weight 0 before uninstall"
  fi
  if ! wait_ingress_canary_weight 0; then
    rollback_canary "ingress-nginx did not apply canary weight 0 before uninstall"
  fi
  step "uninstalling sensor-canary after weight 0"
  if ! helm uninstall sensor-canary -n sensor --wait --timeout 3m; then
    printf '%s FAIL uninstall sensor-canary after promote of %s\n' "$(now)" "$TAG" >&2
    exit 1
  fi
  step "PASS canary promoted ${TAG}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${CANARY_SELF_TEST:-}" == 1 ]]; then
    self_test
    exit 0
  fi
  main "$@"
fi

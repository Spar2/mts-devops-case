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
#   CANARY_SELF_TEST=1  check finite-number parsing and weight bounds, then exit
#
# make k8s-canary passes CANARY_TAG (default <stable-sha>-canary), not TAG.
# The chart sets APP_VERSION to the image tag. GET /ready returns it as JSON
# "version" and as X-App-Version.
#
# Each step installs release sensor-canary (track=canary, canary.enabled=true,
# canary.weight=W) and waits until ingress-nginx shows that weight. Then:
#   1. scripts/smoke.sh with X_CANARY=always and EXPECT_VERSION=TAG
#   2. WEIGHT_SAMPLE_N requests to /ready with no X-Canary header. The share of
#      responses whose version is TAG must sit in the weight band (integer
#      percent, hits*100/N): 10 → 2–25, 50 → 30–70, 100 → 100. Another weight
#      w in 1..99 → max(1, w-20)..min(99, w+20). 0 → 0.
#   3. The same band on the ingress-nginx counter delta around that sample:
#      canary label =~ .+sensor-canary.+  over all requests in namespace sensor.
#      Header traffic from the smoke is outside this delta.
#   4. Prometheus, after 10 requests with X-Canary: always and ANALYSIS_WAIT_S:
#        min(up{namespace="sensor",service="sensor-canary-api"}) == 1
#          (only if the target appears within 120s)
#        canary request rate > 0
#        5xx share of those requests >= 0 and < 0.05
#      NaN, +Inf, -Inf, empty and non-numeric samples roll back. mawk turns
#      NaN and Inf into 0, so a bare `v+0 < 0.05` would accept them.
#      Prometheus unreachable at PROM_URL also rolls the canary back.
# A failed install or gate sets weight 0, uninstalls sensor-canary, prints
# "ROLLBACK canary: <reason>", and does not change release sensor.
# Success: deploy.sh moves stable to TAG and waits for rollout, canary weight
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

# Drain canary traffic, delete the release, and stop. Release sensor is not
# upgraded, rolled back, or uninstalled here.
rollback_canary() {
  local reason=$1
  set_canary_weight 0 || true
  step "helm uninstall sensor-canary"
  helm uninstall sensor-canary -n sensor --wait --timeout 3m --ignore-not-found || true
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

# Ingress sends X-Canary: always to the canary web pod. /ready is proxied to
# the API, so these hits move the canary series of nginx_ingress_controller_requests.
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

# Unweighted requests, then the ingress-nginx counter delta around them.
weight_gate() {
  local weight=$1
  local lo hi n hits http_ok i status
  local header_version body_version pct
  local q_all q_canary
  local before_all before_canary after_all after_canary
  local total_delta share_pct share_rc
  local work hdr body deadline
  read -r lo hi < <(weight_bounds "$weight")
  n=$weight_sample_n
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
  step "sending ${n} requests to ${base_url}/ready without X-Canary (want ${lo}-${hi}% version ${TAG})"
  for ((i = 1; i <= n; i++)); do
    status="$(
      curl --silent --globoff --connect-timeout 3 --max-time 10 \
        -D "$hdr" -o "$body" -w '%{http_code}' \
        "${base_url}/ready" || true
    )"
    if [[ ! "$status" =~ ^[0-9]{3}$ ]]; then
      status=000
    fi
    if [[ "$status" != "200" ]]; then
      continue
    fi
    http_ok=$((http_ok + 1))
    header_version="$(header_app_version "$hdr")"
    body_version="$(body_app_version "$body")"
    if [[ "$header_version" == "$TAG" && "$body_version" == "$TAG" ]]; then
      hits=$((hits + 1))
    fi
  done
  rm -rf -- "$work"

  pct=$((hits * 100 / n))
  step "canary version share ${hits}/${n} = ${pct}% at weight ${weight} (http 200: ${http_ok}), want ${lo}-${hi}%"
  if ((pct < lo || pct > hi)); then
    rollback_canary "canary response share ${pct}% (${hits}/${n}) at weight ${weight} outside ${lo}-${hi}%"
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
    if awk -v d="$total_delta" -v need="$n" 'BEGIN { exit !(d + 0 >= need * 0.8) }'; then
      break
    fi
    if ((SECONDS >= deadline)); then
      rollback_canary "ingress request counter rose by ${total_delta}, want at least 80% of ${n} weight-sample requests at weight ${weight}"
    fi
    sleep 3
  done

  share_rc=0
  share_pct="$(metric_share_percent "$before_canary" "$after_canary" "$before_all" "$after_all")" || share_rc=$?
  if [[ "$share_rc" -ne 0 ]]; then
    rollback_canary "ingress canary counter delta is not usable at weight ${weight} (canary ${before_canary}->${after_canary}, all ${before_all}->${after_all})"
  fi
  step "ingress canary share ${share_pct}% at weight ${weight} (canary ${before_canary}->${after_canary}, all ${before_all}->${after_all}), want ${lo}-${hi}%"
  if ((share_pct < lo || share_pct > hi)); then
    rollback_canary "ingress canary share ${share_pct}% at weight ${weight} outside ${lo}-${hi}%"
  fi
  step "PASS weight ${weight}"
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

  # Основной гейт — метрики ingress-nginx (трафик и доля 5xx canary-апстрима): их
  # Prometheus уже собирает. Target canary из нового ServiceMonitor Prometheus
  # подхватывает с задержкой (operator + reload; в e2e на k3s бывало > 180 с),
  # поэтому up проверяется, только если target успел появиться за 120 с.
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
    step "NOTE target sensor-canary-api not discovered yet; gate uses ingress-nginx metrics only"
  fi

  step "query ${q_rate}"
  load_finite_sample "$q_rate" "$weight"
  step "canary ingress request rate=${sample_value}/s"
  if ! metric_positive "$sample_value"; then
    rollback_canary "${q_rate}=${sample_value} at weight ${weight}, want > 0"
  fi

  step "query ${q_err}"
  load_finite_sample "$q_err" "$weight"
  step "canary 5xx ratio=${sample_value}"
  if ! metric_below "$sample_value" 0.05; then
    rollback_canary "canary 5xx ratio ${sample_value} at weight ${weight}, want >= 0 and < 0.05"
  fi
  step "PASS metrics at weight ${weight}"
}

self_test() {
  local lo hi work hdr body got
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
  step "promoting ${TAG} to stable via deploy.sh"
  if ! "${ROOT}/scripts/deploy.sh" "$TAG"; then
    rollback_canary "promote via deploy.sh failed for ${TAG}"
  fi
  step "waiting for stable rollout of tag ${TAG}"
  if ! kubectl -n sensor rollout status deployment/sensor-api --timeout=180s; then
    rollback_canary "stable api rollout did not finish for ${TAG}"
  fi
  if ! kubectl -n sensor rollout status deployment/sensor-web --timeout=180s; then
    rollback_canary "stable web rollout did not finish for ${TAG}"
  fi
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

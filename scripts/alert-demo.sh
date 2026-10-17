#!/usr/bin/env bash
# Prove Alertmanager delivers SensorGatewayDown to the in-cluster sink.
#
# Scales deployment/sensor-api in namespace sensor to 0, polls Prometheus
# until SensorGatewayDown is firing, checks the same alert in Alertmanager,
# then waits until deploy/alert-sink logs a new SensorGatewayDown line.
# Queries stay inside the pods (wget to 127.0.0.1). No port-forward.
#
# A running canary Service *-api keeps sum(up) above 0, so the alert stays
# quiet until that Deployment is scaled down too.
#
# On any exit, including failure and SIGINT, replicas go back to 1 and the
# rollout is waited out.
#
# Usage: alert-demo.sh

set -euo pipefail

usage() {
  printf 'usage: %s\n' "${0##*/}" >&2
}

now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

pass() {
  printf 'PASS %s\n' "$*"
}

# $1 kind: prom (Prometheus /api/v1/alerts) or am (Alertmanager /api/v2/alerts)
# $2 alertname
# $3 raw JSON
# prom prints pending|firing|absent|invalid
# am prints "<state>\t<receiver,receiver>" or absent|invalid
parse_alert() {
  ALERT_KIND="$1" ALERT_NAME="$2" ALERT_JSON="$3" python3 - <<'PY'
import json
import os

kind = os.environ["ALERT_KIND"]
name = os.environ["ALERT_NAME"]
raw = os.environ.get("ALERT_JSON", "").strip()

if not raw:
    print("absent")
    raise SystemExit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("invalid")
    raise SystemExit(0)

def alert_labels(alert):
    if not isinstance(alert, dict):
        return {}
    labels = alert.get("labels")
    if not isinstance(labels, dict):
        return {}
    return labels

if kind == "prom":
    alerts = []
    if isinstance(data, dict):
        inner = data.get("data")
        if isinstance(inner, dict) and isinstance(inner.get("alerts"), list):
            alerts = inner["alerts"]
    for alert in alerts:
        if alert_labels(alert).get("alertname") == name:
            state = alert.get("state") if isinstance(alert, dict) else None
            print(state or "absent")
            break
    else:
        print("absent")
elif kind == "am":
    alerts = data if isinstance(data, list) else []
    for alert in alerts:
        if alert_labels(alert).get("alertname") != name:
            continue
        status = alert.get("status") if isinstance(alert, dict) else {}
        if not isinstance(status, dict):
            status = {}
        state = status.get("state") or "present"
        receivers = []
        recs = alert.get("receivers") if isinstance(alert, dict) else []
        if isinstance(recs, list):
            for rec in recs:
                if isinstance(rec, dict) and rec.get("name"):
                    receivers.append(str(rec["name"]))
        print(state + "\t" + ",".join(receivers))
        break
    else:
        print("absent")
else:
    print("invalid")
PY
}

prom_json() {
  kubectl -n monitoring exec prometheus-mon-kube-prometheus-stack-prometheus-0 \
    -c prometheus -- wget -qO- http://127.0.0.1:9090/api/v1/alerts
}

am_json() {
  kubectl -n monitoring exec alertmanager-mon-kube-prometheus-stack-alertmanager-0 \
    -c alertmanager -- wget -qO- http://127.0.0.1:9093/api/v2/alerts
}

# How many log lines currently mention SensorGatewayDown. 0 if the sink
# is not ready yet. The image pretty-prints the webhook body, so the
# alertname is its own line.
sink_hits() {
  local logs n
  if ! logs="$(kubectl -n monitoring logs deploy/alert-sink 2>/dev/null)"; then
    printf '0\n'
    return 0
  fi
  n="$(printf '%s\n' "$logs" | grep -F -c -- SensorGatewayDown || true)"
  n="${n//[^0-9]/}"
  if [[ -z "$n" ]]; then
    n=0
  fi
  printf '%s\n' "$n"
}

restore() {
  local rc=${1:-1}
  trap - EXIT INT TERM
  if [[ ! "$rc" =~ ^[0-9]+$ ]]; then
    rc=1
  fi
  printf '%s restoring deployment/sensor-api to 1 replica\n' "$(now)"
  if ! kubectl -n sensor scale deployment/sensor-api --replicas=1; then
    printf 'FAIL could not scale deployment/sensor-api to 1\n' >&2
    exit 1
  fi
  if ! kubectl -n sensor rollout status deployment/sensor-api --timeout=180s; then
    printf 'FAIL deployment/sensor-api rollout after restore\n' >&2
    exit 1
  fi
  exit "$rc"
}

sleep_remaining() {
  local deadline=$1
  local step=$2
  local left=$((deadline - SECONDS))
  if (( left <= 0 )); then
    return 0
  fi
  if (( left < step )); then
    step=$left
  fi
  sleep "$step"
}

main() {
  local hits_before hits_now json state prev
  local deadline am_deadline log_deadline
  local am_line am_state am_receivers

  if [[ $# -ne 0 ]]; then
    usage
    exit 2
  fi
  if ! command -v kubectl >/dev/null 2>&1; then
    printf 'kubectl is required\n' >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 is required\n' >&2
    exit 1
  fi
  if ! kubectl -n sensor get deployment sensor-api >/dev/null; then
    printf 'deployment sensor-api not found in namespace sensor\n' >&2
    exit 1
  fi

  hits_before="$(sink_hits)"
  if [[ ! "$hits_before" =~ ^[0-9]+$ ]]; then
    hits_before=0
  fi
  printf '%s alert-sink SensorGatewayDown lines before outage: %s\n' "$(now)" "$hits_before"

  trap 'restore $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  printf '%s scaling deployment/sensor-api to 0\n' "$(now)"
  kubectl -n sensor scale deployment/sensor-api --replicas=0

  prev=""
  state=""
  deadline=$((SECONDS + 300))
  printf '%s waiting for SensorGatewayDown to fire (every 10s, up to 5m)\n' "$(now)"
  while (( SECONDS < deadline )); do
    state="invalid"
    if json="$(prom_json)"; then
      if ! state="$(parse_alert prom SensorGatewayDown "$json")"; then
        state="invalid"
      fi
    else
      printf '%s prometheus query failed\n' "$(now)" >&2
    fi
    if [[ "$state" != "$prev" && ( "$state" == "pending" || "$state" == "firing" ) ]]; then
      printf '%s SensorGatewayDown %s\n' "$(now)" "$state"
    fi
    prev=$state
    if [[ "$state" == "firing" ]]; then
      break
    fi
    sleep_remaining "$deadline" 10
  done
  if [[ "$state" != "firing" ]]; then
    printf 'FAIL prometheus SensorGatewayDown did not fire within 5m\n' >&2
    exit 1
  fi
  pass "prometheus SensorGatewayDown firing"

  am_state=""
  am_receivers=""
  am_deadline=$((SECONDS + 60))
  printf '%s waiting for Alertmanager to list SensorGatewayDown\n' "$(now)"
  while (( SECONDS < am_deadline )); do
    am_line="invalid"
    if json="$(am_json)"; then
      if ! am_line="$(parse_alert am SensorGatewayDown "$json")"; then
        am_line="invalid"
      fi
    else
      printf '%s alertmanager query failed\n' "$(now)" >&2
    fi
    case "$am_line" in
      *$'\t'*)
        am_state="${am_line%%$'\t'*}"
        am_receivers="${am_line#*$'\t'}"
        ;;
      *)
        am_state=$am_line
        am_receivers=""
        ;;
    esac
    if [[ -n "$am_state" && "$am_state" != "absent" && "$am_state" != "invalid" ]]; then
      printf '%s alertmanager SensorGatewayDown %s receivers=%s\n' \
        "$(now)" "$am_state" "${am_receivers:-none}"
      break
    fi
    sleep_remaining "$am_deadline" 10
  done
  if [[ -z "$am_state" || "$am_state" == "absent" || "$am_state" == "invalid" ]]; then
    printf 'FAIL alertmanager did not list SensorGatewayDown within 60s\n' >&2
    exit 1
  fi
  if [[ -n "$am_receivers" && ",${am_receivers}," != *",sensor-webhook,"* ]]; then
    printf 'FAIL alertmanager SensorGatewayDown receivers=%s\n' "$am_receivers" >&2
    exit 1
  fi
  pass "alertmanager SensorGatewayDown ${am_state}"

  hits_now=$hits_before
  log_deadline=$((SECONDS + 90))
  printf '%s waiting up to 90s for alert-sink to log SensorGatewayDown\n' "$(now)"
  while (( SECONDS < log_deadline )); do
    hits_now="$(sink_hits)"
    if [[ "$hits_now" =~ ^[0-9]+$ ]] && (( hits_now > hits_before )); then
      pass "alert-sink log contains SensorGatewayDown"
      return 0
    fi
    sleep_remaining "$log_deadline" 5
  done
  printf 'FAIL alert-sink log had no new SensorGatewayDown within 90s (before=%s now=%s)\n' \
    "$hits_before" "$hits_now" >&2
  exit 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

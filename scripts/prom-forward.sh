#!/usr/bin/env bash
# Port-forward Prometheus на 127.0.0.1:9090 для метрического гейта canary.sh.
# Если Prometheus уже отвечает на /-/ready, ничего не делает. Иначе поднимает
# port-forward в фоне и ждёт готовности до 30 с; не дождался — exit 1.
set -euo pipefail
url="${PROM_URL:-http://127.0.0.1:9090}"
ready() { curl --noproxy '*' -sf --max-time 3 -o /dev/null "${url}/-/ready"; }
if ready; then
  echo "prometheus ready at ${url}"
  exit 0
fi
nohup kubectl -n monitoring port-forward svc/mon-kube-prometheus-stack-prometheus 9090:9090 \
  >/tmp/prom-forward.log 2>&1 &
for _ in $(seq 1 30); do
  if ready; then
    echo "prometheus ready at ${url} (port-forward pid $!)"
    exit 0
  fi
  sleep 1
done
echo "prometheus not ready at ${url}; see /tmp/prom-forward.log" >&2
exit 1

#!/usr/bin/env bash
# Проверка NetworkPolicy чарта: под из чужого namespace не достаёт API,
# под web того же релиза достаёт. Использует уже загруженный в кластер образ web.
set -euo pipefail
tag="${1:?usage: netpol-check.sh TAG}"
image="${IMAGE_REPO_PREFIX:-ghcr.io/spar2/mts-devops-case}/sensor-web:${tag}"
kubectl -n default delete pod np-probe --ignore-not-found >/dev/null
kubectl -n default run np-probe --image="${image}" --image-pull-policy=IfNotPresent --restart=Never \
  --command -- sh -c 'wget -qO- -T5 http://sensor-api.sensor.svc:8000/ready >/dev/null 2>&1 && echo REACHED || echo BLOCKED' >/dev/null
kubectl -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/np-probe --timeout=90s >/dev/null
outside="$(kubectl -n default logs np-probe)"
kubectl -n default delete pod np-probe --wait=false >/dev/null
web="$(kubectl -n sensor get pod -l app.kubernetes.io/instance=sensor,app.kubernetes.io/component=web -o name | head -n1)"
inside="$(kubectl -n sensor exec "${web}" -- sh -c 'wget -qO- -T5 http://sensor-api:8000/ready >/dev/null 2>&1 && echo REACHED || echo BLOCKED')"
echo "из namespace default: ${outside} (ожидается BLOCKED)"
echo "из пода web релиза sensor: ${inside} (ожидается REACHED)"
if [[ "${outside}" == BLOCKED && "${inside}" == REACHED ]]; then
  echo "PASS NetworkPolicy"
else
  echo "FAIL NetworkPolicy (контроллер NetworkPolicy в кластере не работает или правило неверно)" >&2
  exit 1
fi

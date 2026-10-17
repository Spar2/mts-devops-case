#!/usr/bin/env bash
# Проверка NetworkPolicy чарта: под из чужого namespace не достаёт ни API, ни web;
# web доступен через ingress-nginx; под web того же релиза достаёт API. Использует уже загруженный в кластер образ web.
set -euo pipefail
tag="${1:?usage: netpol-check.sh TAG}"
image="${IMAGE_REPO_PREFIX:-ghcr.io/spar2/mts-devops-case}/sensor-web:${tag}"
kubectl -n default delete pod np-probe --ignore-not-found >/dev/null
# shellcheck disable=SC2016 # $u раскрывает sh внутри пода
kubectl -n default run np-probe --image="${image}" --image-pull-policy=IfNotPresent --restart=Never \
  --command -- sh -c 'for u in http://sensor-api.sensor.svc:8000/ready http://sensor-web.sensor.svc/; do wget -qO- -T5 "$u" >/dev/null 2>&1 && printf R || printf B; done' >/dev/null
kubectl -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/np-probe --timeout=90s >/dev/null
outside="$(kubectl -n default logs np-probe)"
kubectl -n default delete pod np-probe --wait=false >/dev/null
web="$(kubectl -n sensor get pod -l app.kubernetes.io/instance=sensor,app.kubernetes.io/component=web -o name | head -n1)"
inside="$(kubectl -n sensor exec "${web}" -- sh -c 'wget -qO- -T5 http://sensor-api:8000/ready >/dev/null 2>&1 && echo REACHED || echo BLOCKED')"
outside_web="${outside:1:1}"
outside="${outside:0:1}"
[[ "${outside}" == B ]] && outside=BLOCKED || outside=REACHED
[[ "${outside_web}" == B ]] && outside_web=BLOCKED || outside_web=REACHED
code="$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 10 "http://sensor.localtest.me:${INGRESS_PORT:-80}/")"
[[ "${code}" == 200 ]] && via_ingress=REACHED || via_ingress="BLOCKED (HTTP ${code})"
echo "API из namespace default: ${outside} (ожидается BLOCKED)"
echo "web из namespace default: ${outside_web} (ожидается BLOCKED)"
echo "web через ingress-nginx: ${via_ingress} (ожидается REACHED)"
echo "из пода web релиза sensor: ${inside} (ожидается REACHED)"
if [[ "${outside}" == BLOCKED && "${outside_web}" == BLOCKED && "${via_ingress}" == REACHED && "${inside}" == REACHED ]]; then
  echo "PASS NetworkPolicy"
else
  echo "FAIL NetworkPolicy (контроллер NetworkPolicy в кластере не работает или правило неверно)" >&2
  exit 1
fi

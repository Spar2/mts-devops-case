# Мониторинг sensor-gateway

Чарт `prometheus-community/kube-prometheus-stack` версии **65.1.1**, релиз `mon`, namespace `monitoring`. Считаем один небольшой узел: etcd, kube-controller-manager, kube-scheduler и kube-proxy не скрейпятся (на k3s отдельных endpoint нет), node-exporter включён. Prometheus хранит данные 1 день, лимит памяти 1Gi. `serviceMonitorSelectorNilUsesHelmValues` и `ruleSelectorNilUsesHelmValues` выключены, поэтому Prometheus берёт ServiceMonitor из namespace `sensor` и PrometheusRule с меткой `release: mon`.

Установка (нужны Helm 3, kubectl и ingress-nginx с классом `nginx`):

```bash
./scripts/monitoring-install.sh
```

Grafana: http://grafana.localtest.me (`localtest.me` указывает на 127.0.0.1). Демо-логин `admin`, пароль `admin`. Для стенда создайте Secret с ключами `admin-user` и `admin-password` и пропишите его имя в `grafana.admin.existingSecret` (поле `adminPassword` при этом уберите). Дашборд `sensor-gateway` лежит в ConfigMap с меткой `grafana_dashboard: "1"`, sidecar подхватывает его сам.

## Зачем эти метрики

API пишет текст Prometheus на `GET /metrics`.

- `service_up` — gauge процесса, на дашборде stat. Пока обработчик `/metrics` жив, значение 1.
- `rate(http_requests_total[1m])` — запросы в секунду. Счётчик растёт на каждом HTTP-запросе, включая сам scrape `/metrics`.
- `service_probe_latency_seconds` — задержка последнего `POST /api/v1/service/probe` из окна «Служба».
- `up{job=~".*sensor.*api.*"}` — жив ли scrape Service API. Job выглядит как `sensor/sensor-api` и, если выкатана канарейка, `sensor/sensor-canary-api`.

Алерт **SensorGatewayDown** (critical, 1 минута) считает `(sum(up{namespace="sensor", service=~".*-api"}) or vector(0)) == 0`. При `scale --replicas=0` ряд `service_up` исчезает вместе с подом, и сравнение `max(service_up) < 1` не получает точку. `or vector(0)` превращает «рядов нет» в ноль, и алерт зажигается. Пока жив хотя бы один Service `*-api`, сумма больше нуля.

Алерты **SensorGatewayNoReplicas** (critical: у Deployment в namespace sensor spec.replicas>0, а доступных реплик 0 минуту, kube-state-metrics) и **SensorGatewayPodRestarts** (warning: больше 3 рестартов контейнера за 15 минут).

## Доставка

Корень маршрута Alertmanager — receiver `null`: такой алерт никуда не отправляется. Дочерний маршрут `alertname =~ "SensorGateway.*"` ведёт в receiver `sensor-webhook`. Это POST на `http://alert-sink.monitoring.svc:8080/alert` с `send_resolved: true`. И корень, и этот дочерний маршрут задают `group_wait` 10 с, `group_interval` 30 с, `repeat_interval` 1 ч. `Watchdog` и `InfoInhibitor` своим дочерним маршрутом остаются на `null`.

Приёмник — Deployment и Service `alert-sink` в namespace `monitoring` (`alert-sink.yaml`). Образ `mendhak/http-https-echo:34` слушает порт 8080 и пишет тело запроса в stdout. Проверки готовности ходят на `/` и в лог не попадают: в теге 34 `LOG_IGNORE_PATH` сравнивается с путём целиком. `scripts/monitoring-install.sh` применяет манифест и ждёт rollout.

Доставку проверяет `./scripts/alert-demo.sh` (то же: `make k8s-alert-demo`), без port-forward. Скрипт ставит Deployment `sensor-api` на 0 реплик и раз в 10 с, не дольше 5 минут, читает Prometheus из пода: `kubectl exec` в `prometheus-mon-kube-prometheus-stack-prometheus-0`, контейнер `prometheus`, `wget` на `http://127.0.0.1:9090/api/v1/alerts`. Печатает переходы `pending` и `firing` с меткой времени. Затем так же читает Alertmanager: под `alertmanager-mon-kube-prometheus-stack-alertmanager-0`, контейнер `alertmanager`, порт 9093, `/api/v2/alerts`. После этого до 90 с ждёт новую строку `SensorGatewayDown` в `kubectl -n monitoring logs deploy/alert-sink`. Успех — строки `PASS`. `trap` на выходе всегда возвращает реплики к 1 и ждёт rollout, в том числе если проверка сорвалась. Запущенная канарейка `*-api` держит сумму `up` больше нуля, и `SensorGatewayDown` тогда не загорится.

Ручной просмотр UI Prometheus:

```bash
kubectl -n sensor scale deployment/sensor-api --replicas=0
kubectl -n monitoring port-forward svc/mon-kube-prometheus-stack-prometheus 9090:9090
```

http://127.0.0.1:9090/alerts — через минуту `SensorGatewayDown` станет Firing. Вернуть под: `kubectl -n sensor scale deployment/sensor-api --replicas=1`.

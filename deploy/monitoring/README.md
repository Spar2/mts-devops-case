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

Алерт **SensorGatewaySlowProbe** (warning, 5 минут): `service_probe_latency_seconds > 0.5`.

## Как увидеть, что алерт горит

Обнулить API (имя Deployment стабильного релиза — `sensor-api`; канарейку тоже обнулите, иначе её `up` оставит сумму больше нуля):

```bash
kubectl -n sensor scale deployment/sensor-api --replicas=0
kubectl -n monitoring port-forward svc/mon-kube-prometheus-stack-prometheus 9090:9090
```

Откройте http://127.0.0.1:9090/alerts. Через минуту `SensorGatewayDown` перейдёт в Firing.

Вернуть под: `kubectl -n sensor scale deployment/sensor-api --replicas=1`.

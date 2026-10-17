# Мониторинг sensor-gateway

Чарт `prometheus-community/kube-prometheus-stack` версии **65.1.1**, релиз `mon`, namespace `monitoring`. Считаем один небольшой узел: etcd, kube-controller-manager, kube-scheduler и kube-proxy не скрейпятся (на k3s отдельных endpoint нет), node-exporter включён. Prometheus хранит данные 1 день, лимит памяти 1Gi. `serviceMonitorSelectorNilUsesHelmValues` и `ruleSelectorNilUsesHelmValues` выключены, поэтому Prometheus берёт ServiceMonitor из namespace `sensor` и PrometheusRule с меткой `release: mon`.

Установка (нужны Helm 3, kubectl и ingress-nginx с классом `nginx`):

```bash
./scripts/monitoring-install.sh
```

Grafana: http://grafana.localtest.me:8081 в режиме k3d, :80 при `K3D=0` (`localtest.me` указывает на 127.0.0.1). Логин `admin`, случайный пароль в лог не пишется: `make status` печатает команду `kubectl`, само значение — `SHOW_SECRETS=1 make status`. Пароль лежит в SOPS-файле `deploy/secrets/grafana-admin.enc.yaml`, в кластер попадает Secret `grafana-admin` (`grafana.admin.existingSecret`). Смена пароля — `scripts/grafana-rotate.sh`. Дашборд `sensor-gateway` лежит в ConfigMap с меткой `grafana_dashboard: "1"`, sidecar подхватывает его сам.

## Зачем эти метрики

API пишет текст Prometheus на `GET /metrics` библиотекой `prometheus_client` 0.26.0. Снаружи путь закрывает nginx web (403). Ingress направляет запрос на Service web и сам путь не режет. ServiceMonitor скрейпит Service API напрямую.

- `http_request_duration_seconds` — гистограмма задержки HTTP. Метки `method`, `path` (шаблон маршрута; несовпавший путь — `unmatched`), `status`.
- `http_requests_total` — счётчик запросов с теми же метками, включая scrape `/metrics`. На дашборде `sum by (service) (rate(...[2m]))`.
- `service_up` — 1, если проверка готовности проходит (ключ сессии подписывает и проверяет токен), иначе 0. Тот же результат у `GET /ready` (503, если проверка не прошла).
- `service_probe_latency_seconds` — измеренное время последнего `POST /api/v1/service/probe`, без фиксированной паузы.
- `process_resident_memory_bytes` и остальные `process_*` / `python_*` — коллекторы реестра по умолчанию.
- `up{job=~".*sensor.*api.*"}` — жив ли scrape Service API. Job выглядит как `sensor/sensor-api` и, если выкатана канарейка, `sensor/sensor-canary-api`.

Алерт **SensorGatewayDown** (critical, 1 минута) считает `(sum(up{namespace="sensor", service=~".*-api"}) or vector(0)) == 0`. При `scale --replicas=0` ряд приложения исчезает вместе с подом, и сравнение `service_up < 1` не получает точку. `or vector(0)` превращает «рядов нет» в ноль, и алерт зажигается. Пока жив хотя бы один Service `*-api`, сумма больше нуля.

Алерт **SensorGatewayHighLatency** (warning, 2 минуты) считает `histogram_quantile(0.95, sum by (le, service) (rate(http_request_duration_seconds_bucket{namespace="sensor"}[5m]))) > 0.5`. Это p95 гистограммы HTTP, не gauge probe. Пока трафика нет, `rate` пустой и условие ложно; при p95 выше 0.5 с алерт зажигается. На дашборде та же формула, порог 0.5 с.

Алерты **SensorGatewayNoReplicas** (critical: у Deployment в namespace sensor spec.replicas>0, а доступных реплик 0 минуту, kube-state-metrics) и **SensorGatewayPodRestarts** (warning: больше 3 рестартов контейнера за 15 минут).

`make k8s-alert-demo` по-прежнему гасит `deployment/sensor-api` и проверяет доставку **SensorGatewayDown**. `SensorGatewayHighLatency` попадает в тот же маршрут `alertname =~ "SensorGateway.*"`, отдельно на кластере не поджигался.

## Доставка

Корень маршрута Alertmanager — receiver `null`: такой алерт никуда не отправляется. Дочерний маршрут `alertname =~ "SensorGateway.*"` ведёт в receiver `sensor-webhook`. Это POST на `http://alert-sink.monitoring.svc:8080/alert` с `send_resolved: true`. И корень, и этот дочерний маршрут задают `group_wait` 10 с, `group_interval` 30 с, `repeat_interval` 1 ч. `Watchdog` и `InfoInhibitor` своим дочерним маршрутом остаются на `null`.

Приёмник — Deployment и Service `alert-sink` в namespace `monitoring` (`alert-sink.yaml`). Образ `mendhak/http-https-echo:34` слушает порт 8080 и пишет тело запроса в stdout. Проверки готовности ходят на `/` и в лог не попадают: в теге 34 `LOG_IGNORE_PATH` сравнивается с путём целиком. `scripts/monitoring-install.sh` применяет манифест и ждёт rollout.

Доставку проверяет `./scripts/alert-demo.sh` (то же: `make k8s-alert-demo`), без port-forward. Скрипт ставит Deployment `sensor-api` на 0 реплик и раз в 10 с, не дольше 5 минут, читает Prometheus из пода: `kubectl exec` в `prometheus-mon-kube-prometheus-stack-prometheus-0`, контейнер `prometheus`, `wget` на `http://127.0.0.1:9090/api/v1/alerts`. Печатает переходы `pending` и `firing` с меткой времени. Затем так же читает Alertmanager: под `alertmanager-mon-kube-prometheus-stack-alertmanager-0`, контейнер `alertmanager`, порт 9093, `/api/v2/alerts`. После этого до 90 с ждёт новую строку `SensorGatewayDown` в `kubectl -n monitoring logs deploy/alert-sink`. Успех — строки `PASS`. `trap` на выходе всегда возвращает реплики к числу до проверки (если оно было 0 или пустое — к 2, это значение чарта stable) и ждёт rollout, в том числе если проверка сорвалась. Перед `scale --replicas=0` скрипт удаляет HPA `sensor-api`: при `minReplicas: 2` контроллер поднял бы поды обратно, и алерт не продержался бы минуту. На выходе тот же объект HPA применяется снова. Запущенная канарейка `*-api` держит сумму `up` больше нуля, и `SensorGatewayDown` тогда не загорится.

Ручной просмотр UI Prometheus:

```bash
kubectl -n sensor scale deployment/sensor-api --replicas=0
kubectl -n monitoring port-forward svc/mon-kube-prometheus-stack-prometheus 9090:9090
```

http://127.0.0.1:9090/alerts — через минуту `SensorGatewayDown` станет Firing. HPA `sensor-api` при этом надо снять (`kubectl -n sensor delete hpa sensor-api`), иначе minReplicas вернёт поды. Вернуть Deployment: `kubectl -n sensor scale deployment/sensor-api --replicas=2` и снова поставить HPA (`helm upgrade` релиза `sensor` или apply сохранённого объекта).

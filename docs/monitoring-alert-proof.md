# Проверка алерта SensorGatewayDown (k3d, 2026-10-17 MSK)

Стенд: k3d v5.7.5 (k3s v1.31.4+k3s1) на box, kube-prometheus-stack 65.1.1, релиз `sensor` в ns `sensor`.
Образы мониторинга импортированы через `scripts/k3d-preload-images.sh` (из подов box нет egress).

Шаги:
1. 01:49:51 MSK — `kubectl -n sensor scale deploy sensor-api --replicas=0`.
2. 01:51:12 — алерт в Prometheus в состоянии `pending`.
3. 01:52:12 — `firing` (окно `for: 1m`), Alertmanager получил алерт (`startsAt 22:52:05Z` = 01:52:05 MSK).
4. После проверки `--replicas=1`, алерт ушёл в resolved.

Скриншоты: `docs/img/prometheus-alert-firing.png`, `docs/img/alertmanager-alert.png`, дашборд — `docs/img/grafana-sensor-gateway.png`.
Receiver в демо `null`: доставка в почту или чат не настроена, проверялось получение алерта Alertmanager'ом.

## Prometheus `GET /api/v1/alerts` (отфильтровано по Sensor*)

```json
{
  "status": "success",
  "data": {
    "alerts": [
      {
        "labels": {
          "alertname": "SensorGatewayDown",
          "severity": "critical"
        },
        "annotations": {
          "description": "В namespace sensor уже минуту нет ни одного живого target Service *-api (stable sensor-api и канарейка sensor-canary-api). sum(up) равен 0, в том числе когда поды сняты и ряд up исчез.",
          "summary": "sensor-gateway: API не отвечает"
        },
        "state": "firing",
        "activeAt": "2026-10-16T22:51:05.814620896Z",
        "value": "0e+00"
      }
    ]
  }
}
```

## Alertmanager `GET /api/v2/alerts?filter=alertname="SensorGatewayDown"`

```json
[
    {
        "annotations": {
            "description": "В namespace sensor уже минуту нет ни одного живого target Service *-api (stable sensor-api и канарейка sensor-canary-api). sum(up) равен 0, в том числе когда поды сняты и ряд up исчез.",
            "summary": "sensor-gateway: API не отвечает"
        },
        "endsAt": "2026-10-16T22:56:05.814Z",
        "fingerprint": "8429c6e096017e1e",
        "receivers": [
            {
                "name": "null"
            }
        ],
        "startsAt": "2026-10-16T22:52:05.814Z",
        "status": {
            "inhibitedBy": [],
            "silencedBy": [],
            "state": "active"
        },
        "updatedAt": "2026-10-16T22:52:05.817Z",
        "generatorURL": "http://mon-kube-prometheus-stack-prometheus.monitoring:9090/graph?g0.expr=%28sum%28up%7Bnamespace%3D%22sensor%22%2Cservice%3D~%22.%2A-api%22%7D%29+or+vector%280%29%29+%3D%3D+0&g0.tab=1",
        "labels": {
            "alertname": "SensorGatewayDown",
            "prometheus": "monitoring/mon-kube-prometheus-stack-prometheus",
            "severity": "critical"
        }
    }
]
```

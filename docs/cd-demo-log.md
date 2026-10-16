# Логи CD в k3d (время в UTC, MSK = UTC+3)

Стенд: k3d, ingress-nginx 4.11.3, kube-prometheus-stack 65.1.1, Prometheus через port-forward (`PROM_URL=http://127.0.0.1:9090`), ingress через port-forward (`INGRESS_PORT=18081`).

## 1. Провал canary → автоматический откат (`scripts/canary-fail-demo.sh s2`)

Canary запускается с неверным секретом: поды готовы, но smoke-вход не проходит.

```text
2026-10-16T22:56:54Z using tag s2
2026-10-16T22:56:54Z creating Secret sensor-secrets-wrong in namespace sensor
namespace/sensor configured
secret/sensor-secrets-wrong created
2026-10-16T22:56:54Z running canary.sh; smoke login should fail and roll the canary back
2026-10-16T22:56:54Z canary s2 weights: 10 50 100
2026-10-16T22:56:54Z CANARY_HELM_ARGS: --set existingSecret=sensor-secrets-wrong
2026-10-16T22:56:54Z installing sensor-canary tag s2 weight 10
Release "sensor-canary" does not exist. Installing it now.
2026-10-16T22:57:16Z smoke X-Canary: always at weight 10
PASS ready 200
PASS metrics contains service_up 1
PASS GET /api/v1/service without cookie 401
FAIL login: HTTP 401, expected 200 and cookie dts_session
FAIL GET /api/v1/service with cookie: no session
FAIL POST /api/v1/service/probe: no session
2026-10-16T22:57:16Z setting canary weight 0
Release "sensor-canary" has been upgraded. Happy Helming!
2026-10-16T22:57:17Z helm uninstall sensor-canary
release "sensor-canary" uninstalled
2026-10-16T22:57:17Z ROLLBACK canary: smoke failed at weight 10
2026-10-16T22:57:17Z canary.sh rolled back (exit 1)
2026-10-16T22:57:17Z helm list -n sensor
NAME  	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART               	APP VERSION
sensor	sensor   	13      	2026-10-17 01:54:06.936181591 +0300 MSK	deployed	sensor-gateway-0.1.0	0.1.0      
2026-10-16T22:57:17Z only stable release sensor remains
2026-10-16T22:57:17Z smoke stable release sensor
PASS ready 200
PASS metrics contains service_up 1
PASS GET /api/v1/service without cookie 401
PASS login cookie dts_session
PASS GET /api/v1/service with cookie 200
PASS POST /api/v1/service/probe 200
2026-10-16T22:57:17Z PASS canary-fail-demo: stable release sensor still serves traffic
```

## 2. Успешный canary 10 → 50 → 100 с метрическим гейтом и promote (`scripts/canary.sh s2`)

```text
2026-10-16T22:58:43Z canary s2 weights: 10 50 100
2026-10-16T22:58:43Z installing sensor-canary tag s2 weight 10
Release "sensor-canary" does not exist. Installing it now.
2026-10-16T22:59:05Z smoke X-Canary: always at weight 10
2026-10-16T22:59:05Z PASS smoke at weight 10
2026-10-16T22:59:05Z sending 10 requests to http://sensor.localtest.me:18081/ready with X-Canary: always
2026-10-16T22:59:05Z waiting 75s before prometheus analysis
2026-10-16T23:00:20Z query min(up{namespace="sensor",service="sensor-canary-api"})
2026-10-16T23:00:20Z min(up sensor-canary-api)=1
2026-10-16T23:00:20Z query sum(rate(http_requests_total{namespace="sensor",service="sensor-canary-api"}[2m]))
2026-10-16T23:00:20Z sum(rate http_requests_total sensor-canary-api)=0.43311194444444445
2026-10-16T23:00:20Z PASS metrics at weight 10
2026-10-16T23:00:20Z PASS canary weight 10
2026-10-16T23:00:20Z installing sensor-canary tag s2 weight 50
Release "sensor-canary" has been upgraded. Happy Helming!
2026-10-16T23:00:21Z smoke X-Canary: always at weight 50
2026-10-16T23:00:21Z PASS smoke at weight 50
2026-10-16T23:00:21Z sending 10 requests to http://sensor.localtest.me:18081/ready with X-Canary: always
2026-10-16T23:00:21Z waiting 75s before prometheus analysis
2026-10-16T23:01:36Z query min(up{namespace="sensor",service="sensor-canary-api"})
2026-10-16T23:01:36Z min(up sensor-canary-api)=1
2026-10-16T23:01:36Z query sum(rate(http_requests_total{namespace="sensor",service="sensor-canary-api"}[2m]))
2026-10-16T23:01:36Z sum(rate http_requests_total sensor-canary-api)=0.5222222222222221
2026-10-16T23:01:36Z PASS metrics at weight 50
2026-10-16T23:01:36Z PASS canary weight 50
2026-10-16T23:01:36Z installing sensor-canary tag s2 weight 100
Release "sensor-canary" has been upgraded. Happy Helming!
2026-10-16T23:01:36Z smoke X-Canary: always at weight 100
2026-10-16T23:01:36Z PASS smoke at weight 100
2026-10-16T23:01:36Z sending 10 requests to http://sensor.localtest.me:18081/ready with X-Canary: always
2026-10-16T23:01:37Z waiting 75s before prometheus analysis
2026-10-16T23:02:52Z query min(up{namespace="sensor",service="sensor-canary-api"})
2026-10-16T23:02:52Z min(up sensor-canary-api)=1
2026-10-16T23:02:52Z query sum(rate(http_requests_total{namespace="sensor",service="sensor-canary-api"}[2m]))
2026-10-16T23:02:52Z sum(rate http_requests_total sensor-canary-api)=0.5222222222222221
2026-10-16T23:02:52Z PASS metrics at weight 100
2026-10-16T23:02:52Z PASS canary weight 100
2026-10-16T23:02:52Z promoting s2 to stable via deploy.sh
deploying sensor tag s2
Release "sensor" has been upgraded. Happy Helming!
PASS deploy sensor s2
2026-10-16T23:02:52Z uninstalling sensor-canary after promote
release "sensor-canary" uninstalled
2026-10-16T23:02:52Z PASS canary promoted s2
EXIT 0
```

## 3. Общая сессия stable и canary

Cookie получена на stable (`X-Canary: never`), запрос с ней к canary (`X-Canary: always`): `GET /api/v1/service` → 200, запрос виден в логах пода sensor-canary-api.

## 4. Откат по smoke (не --atomic)

Первая выкладка образа с подписанными сессиями: smoke не принял новый формат cookie → `helm rollback sensor 0`, stable остался на прежней ревизии. После исправления smoke выкладка прошла.

# Прогон make k8s-up (k3d на box, 2026-10-17 02:15 MSK)

Команда (песочница box: нет vxlan, нет hostPort, из подов нет egress, поэтому NodePort + port-forward и предзагрузка образов):

```bash
K3D=1 K3D_PRELOAD=1 INGRESS_SERVICE_TYPE=NodePort INGRESS_PORT=18081 \
  K3D_EXTRA_ARGS="--k3s-arg --flannel-backend=host-gw@server:0 --k3s-arg --disable=metrics-server@server:0" \
  make k8s-up K3D=1
```

Перед прогоном: удалены кластер, ключ age и зашифрованный секрет (чистый старт). Admission webhook ingress-nginx включён, скрипт дождался его готовности.

```text
#12 [build 6/8] COPY public ./public
#12 CACHED
#13 [build 4/8] RUN npm ci
#13 CACHED
#14 [build 5/8] COPY index.html vite.config.ts tsconfig.json ./
#14 CACHED
#15 [build 7/8] COPY src ./src
#15 CACHED
#16 [stage-1 3/4] COPY nginx.conf /etc/nginx/conf.d/default.conf
#16 CACHED
#17 [stage-1 4/4] COPY --from=build /src/dist /usr/share/nginx/html
#17 CACHED
#18 exporting to image
#18 exporting layers done
#18 writing image sha256:ab3e0c5194db0996af18bb5a37e2e51f35f7fd4fa6dfb786fdf322995a19ea72 done
#18 naming to ghcr.io/spar2/mts-devops-case/sensor-web:c6e0e0a done
#18 DONE 0.0s
k3d image import -c mts ghcr.io/spar2/mts-devops-case/sensor-gateway:c6e0e0a ghcr.io/spar2/mts-devops-case/sensor-web:c6e0e0a
./scripts/deploy.sh c6e0e0a
deploying sensor tag c6e0e0a
Release "sensor" does not exist. Installing it now.
Release sensor (track stable) is in namespace sensor.
Open http://sensor.localtest.me/
Canary: helm upgrade --install sensor-canary <chart> --namespace sensor --set track=canary --set canary.enabled=true --set canary.weight=10
DEMO_PASSWORD is read from Secret sensor-secrets, key DEMO_PASSWORD.
API Service sensor-api port http:8000. Web Service sensor-web port http:80.
ServiceMonitor sensor-api (label release=mon, path /metrics) is applied when monitoring.coreos.com/v1/ServiceMonitor exists.
waiting up to 60s for http://sensor.localtest.me:18081/ready
PASS ready 200
PASS metrics contains service_up 1
PASS GET /api/v1/service without cookie 401
PASS login cookie dts_session
PASS GET /api/v1/service with cookie 200
PASS POST /api/v1/service/probe 200
PASS deploy sensor c6e0e0a
make[1]: Leaving directory '/workspace/mts-devops-case'
real	1m46.056s
user	0m6.076s
sys	0m1.324s
MAKE_EXIT 0
```

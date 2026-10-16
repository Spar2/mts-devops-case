# Промпты Grok CLI

Инструмент: Grok CLI v1.0.52, модель `grok-4.7-build-fast` (имя взято из `grok models`).
Режим: `grok -m grok-4.7-build-fast --always-approve -p "<промпт>"`, пять сессий параллельно
в одном рабочем дереве, каждой выделены непересекающиеся каталоги. Git-команды сессиям запрещены:
ревью, правки и коммиты делал человек.

## Оценка экономии времени

| Поток | Что сгенерировано | Ручная оценка | Фактически (генерация + ревью + правки) |
| --- | --- | --- | --- |
| A k8s | Helm-чарт, k3s-install.sh, Ansible | ~2.5 ч | ~25 мин |
| B CI | ci.yml, ruff.toml | ~40 мин | ~10 мин |
| C CD | deploy/smoke/canary/rollback-demo | ~1.5 ч | ~25 мин |
| D секреты | SOPS+age, init/apply/rotate, README | ~1 ч | ~10 мин |
| E мониторинг | values kube-prometheus-stack, дашборд, алерты | ~1.5 ч | ~10 мин |

Итого примерно 7 ч ручной работы против ~1.5 ч. Оценка субъективная, хронометраж не вёлся.

Что пришлось исправить руками после ревью:
- canary Ingress не получил аннотацию `canary-by-header: X-Canary`, хотя она была в промпте. Найдено при
  прогоне в k3d: smoke путал stable и canary-поды и терял сессию.
- stable smoke в `deploy.sh` теперь шлёт `X-Canary: never`, чтобы во время canary проверять именно stable.
- `.gitignore` секретов: зашифрованный файл каждого стенда свой, в git не кладётся.

## Общий контекст (добавлялся к каждому промпту)

```text
Repo: /workspace/mts-devops-case (MTS hackathon case 1, DevOps pipeline). Apps: services/api = FastAPI "sensor-gateway" on port 8000, endpoints /health /ready /metrics (Prometheus text: service_up, http_requests_total, service_probe_latency_seconds), /api/v1/login (POST json username/password, sets cookie dts_session), /api/v1/service (401 without cookie), POST /api/v1/service/probe. Env: DEMO_PASSWORD (>=12 chars, required), DEMO_USERNAME=demo, SECURE_COOKIES. apps/web = nginx serving SPA on port 80, proxies /api,/health,/ready,/metrics to host "api:8000" (see apps/web/nginx.conf).
Images: ghcr.io/spar2/mts-devops-case/sensor-gateway:<tag> and ghcr.io/spar2/mts-devops-case/sensor-web:<tag> (tag = git short sha, also "latest").
Shared contract: Helm chart at deploy/helm/sensor-gateway (release name "sensor", namespace "sensor"). Values: image.api.repository/tag, image.web.repository/tag, track ("stable"|"canary"), canary.enabled (bool), canary.weight (0-100), ingress.host (default sensor.localtest.me), ingress.className nginx, existingSecret (name of Secret with key DEMO_PASSWORD, default "sensor-secrets"), serviceMonitor.enabled. Canary = second release "sensor-canary" of the same chart with track=canary, canary.enabled=true, which creates an Ingress with nginx.ingress.kubernetes.io/canary annotations. Service for api is named <release>-api and has label app.kubernetes.io/component=api, port name http 8000; web Service <release>-web port 80. Cluster: k3s (or k3d locally) with traefik disabled and ingress-nginx chart 4.11.3. Monitoring: kube-prometheus-stack chart (prometheus-community) version 65.1.1 in namespace monitoring, release "mon", picks ServiceMonitors/PrometheusRules with label release: mon.
Rules: write ONLY files in the directories assigned to you, do not touch other files, do not run git commands. Keep it small and production-sane, pin versions, comments in English or Russian are fine. No databases, queues, ML. When done print a short list of files created.
```

## Поток A

```text
TASK A (k8s). Create: (1) Helm chart deploy/helm/sensor-gateway (Chart.yaml version 0.1.0, values.yaml, templates: api Deployment+Service, web Deployment+Service, Ingress (normal or canary per values), ServiceMonitor (monitoring.coreos.com/v1, label release: mon, path /metrics, guarded by serviceMonitor.enabled and Capabilities check), resources requests/limits small, readiness /ready liveness /health, securityContext runAsNonRoot where possible (api only; web nginx may need root - leave it), env DEMO_PASSWORD from secretKeyRef existingSecret. Web nginx proxies to "api:8000", so the chart must make hostname "api" resolve: add a ConfigMap overriding nginx default.conf proxying to http://<release>-api:8000 mounted over /etc/nginx/conf.d/default.conf (read apps/web/nginx.conf and keep the same locations). (2) scripts/k3s-install.sh: installs k3s v1.31.4+k3s1 with --disable traefik and --write-kubeconfig-mode 644, helm v3.16.3 if missing, then ingress-nginx chart 4.11.3 (repo https://kubernetes.github.io/ingress-nginx) with hostNetwork-free LoadBalancer via k3s servicelb. Must be idempotent. Also support K3D=1 mode: create k3d cluster "mts" (k3s image rancher/k3s:v1.31.4-k3s1, --k3s-arg "--disable=traefik@server:0", -p "8081:80@loadbalancer"). (3) infra/ansible/: inventory.ini (localhost ansible_connection=local), playbook site.yml that runs scripts/k3s-install.sh and then make k8s-deploy target equivalent (helm upgrade --install). Only files under deploy/helm/, scripts/k3s-install.sh, infra/.
```

## Поток B

```text
TASK B (CI). Rewrite .github/workflows/ci.yml (GitHub Actions). Jobs: lint (ruff 0.8.4 via pip, `ruff check services/api`), api (python 3.12, pip install -r services/api/requirements.txt, pytest in services/api with env DEMO_PASSWORD=demo-stand-pass), web (node 24, npm ci && npm run build in apps/web), images (needs lint, api, web): docker/setup-buildx-action@v3, build both images (services/api, apps/web) with docker/build-push-action@v6 load:true, scan with aquasecurity/trivy-action@0.28.0 severity HIGH,CRITICAL exit-code 1 ignore-unfixed, then ONLY on push to main: docker/login-action@v3 to ghcr.io with GITHUB_TOKEN and push tags ghcr.io/spar2/mts-devops-case/sensor-gateway:${short sha} and :latest (same for sensor-web; lowercase). permissions: contents read, packages write. Add helm job: azure/setup-helm@v4 with version v3.16.3, run `helm lint deploy/helm/sensor-gateway` and `helm template` (only if the dir exists: use hashFiles condition). Also create services/api/ruff.toml (target-version py312, line-length 100, select E,F,W,I,B). Then run `ruff check services/api` locally (pip install ruff==0.8.4 --user if needed) and FIX only lint issues in services/api with minimal edits that do not change behaviour; run pytest after (DEMO_PASSWORD=demo-stand-pass). Only touch .github/workflows/ci.yml and services/api/.
```

## Поток C

```text
TASK C (CD). Create scripts/deploy.sh and scripts/smoke.sh and scripts/canary.sh. deploy.sh TAG: `helm upgrade --install sensor deploy/helm/sensor-gateway -n sensor --create-namespace --atomic --wait --timeout 3m --set image.api.tag=$TAG --set image.web.tag=$TAG` (allow IMAGE_REPO_PREFIX override, default ghcr.io/spar2/mts-devops-case, and extra HELM_ARGS), then scripts/smoke.sh; if smoke fails -> `helm rollback sensor 0 -n sensor --wait` (previous revision) and exit 1. smoke.sh BASE_URL (default http://sensor.localtest.me:${INGRESS_PORT:-80}): checks /ready 200, /metrics contains service_up 1, GET /api/v1/service without cookie = 401, login with DEMO_PASSWORD (env, or read from secret sensor-secrets in ns sensor via kubectl) gets cookie, GET /api/v1/service with cookie 200, POST probe 200. Uses curl, retries ready for 60s, prints PASS/FAIL per check. canary.sh TAG [WEIGHT steps default "10 50"]: installs release sensor-canary with --set track=canary,canary.enabled=true,canary.weight=W, for each weight runs smoke against canary using header "X-Canary: always" (chart canary ingress also sets nginx.ingress.kubernetes.io/canary-by-header: X-Canary) and checks Prometheus-free signal: probe returns 200; on success promotes: deploy.sh TAG for stable then `helm uninstall sensor-canary`; on failure uninstall canary (abort) and exit 1. Also scripts/rollback-demo.sh: deploys a deliberately broken tag (e.g. --set image.api.tag=does-not-exist) via deploy.sh to show helm --atomic rollback, then prints `helm history sensor -n sensor`. All bash with set -euo pipefail, shellcheck-clean. Only touch these scripts.
```

## Поток D

```text
TASK D (secrets). Use SOPS 3.9.2 + age 1.2.1. Create: .sops.yaml (creation_rules for path_regex deploy/secrets/.*\.enc\.yaml, encrypted_regex ^(data|stringData)$, age recipient placeholder AGE_PUBLIC_KEY to be replaced by scripts/secrets-init.sh), deploy/secrets/README.md (Russian: how it works, rotation of age key and of DEMO_PASSWORD step by step, what is in git and what is not: age private key lives in ~/.config/sops/age/keys.txt, never in git), scripts/secrets-init.sh: installs sops and age binaries into ~/.local/bin if missing (download from GitHub releases with pinned versions), generates age key if absent, writes recipient into .sops.yaml, creates deploy/secrets/sensor-secrets.enc.yaml from a Secret manifest (name sensor-secrets, ns sensor, stringData DEMO_PASSWORD = $DEMO_PASSWORD or random 24 chars via openssl) encrypted with sops; scripts/secrets-apply.sh: `sops -d deploy/secrets/sensor-secrets.enc.yaml | kubectl apply -f -` (create namespace sensor if missing); scripts/secrets-rotate.sh: generates new password, sops --set or re-encrypt, apply, then `kubectl -n sensor rollout restart deploy -l app.kubernetes.io/component=api` and waits. Add deploy/secrets/.gitignore ignoring *.dec.yaml and keys.txt. Only touch .sops.yaml, deploy/secrets/, scripts/secrets-*.sh.
```

## Поток E

```text
TASK E (monitoring). Create deploy/monitoring/: values-kube-prometheus-stack.yaml for chart prometheus-community/kube-prometheus-stack 65.1.1, trimmed for a single small node (disable kubeEtcd, kubeControllerManager, kubeScheduler, kubeProxy scraping; nodeExporter on; alertmanager enabled with small resources; grafana admin password from existing secret or "admin" note for demo; grafana sidecar dashboards enabled with label grafana_dashboard: "1"; prometheus retention 1d, resources limits ~ 1Gi; serviceMonitorSelectorNilUsesHelmValues false, ruleSelectorNilUsesHelmValues false; grafana ingress host grafana.localtest.me className nginx). dashboard-configmap.yaml: ConfigMap in ns monitoring label grafana_dashboard "1" with a Grafana dashboard JSON "sensor-gateway" panels: service_up (stat), rate(http_requests_total[1m]) (timeseries), service_probe_latency_seconds (timeseries), up{job=~".*sensor.*api.*"}. prometheusrule.yaml: PrometheusRule ns monitoring label release: mon, group sensor-gateway, alerts SensorGatewayDown (expr: absent(service_up{namespace="sensor"}) or max(service_up{namespace="sensor"}) < 1 ... use `(sum(up{namespace="sensor", service=~".*-api"}) or vector(0)) == 0` for 1m, severity critical) and SensorGatewaySlowProbe (service_probe_latency_seconds > 0.5 for 5m, warning), with summary/description annotations in Russian. scripts/monitoring-install.sh: helm repo add prometheus-community https://prometheus-community.github.io/helm-charts, helm upgrade --install mon prometheus-community/kube-prometheus-stack --version 65.1.1 -n monitoring --create-namespace -f values ... --wait --timeout 10m, then kubectl apply dashboard and rule. Plus deploy/monitoring/README.md (Russian, short: why this metric, how to see alert firing: scale api deployment to 0 and watch Prometheus /alerts). Only touch deploy/monitoring/ and scripts/monitoring-install.sh.
```

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

---

# Вторая волна (4 параллельные сессии, та же модель)

Общий контекст второй волны:

```text
Repo /workspace/mts-devops-case (MTS hackathon case 1: DevOps pipeline). Already present: services/api (FastAPI sensor-gateway, app/main.py, tests/), apps/web, Helm chart deploy/helm/sensor-gateway (releases "sensor" stable and "sensor-canary", ns sensor, Secret sensor-secrets key DEMO_PASSWORD), scripts/{k3s-install.sh,deploy.sh,smoke.sh,canary.sh,rollback-demo.sh,secrets-*.sh,monitoring-install.sh}, deploy/monitoring (kube-prometheus-stack 65.1.1 release "mon" ns monitoring), Makefile targets up/k8s-up/k8s-deploy/k8s-canary, .github/workflows/ci.yml. Read relevant files first. Write ONLY the files assigned to you; do not run git; do not touch other files. Keep changes small and pinned. When done print the list of changed files and what you verified.
```

## S — stateless-сессии для stable и canary

```text
Replace the in-memory session dict with a signed stateless cookie: token = base64url(json{u,exp}) + "." + HMAC-SHA256 signature. Signing key derived from env SESSION_SECRET (optional, >=16 chars) combined with the current DEMO_PASSWORD, so rotating DEMO_PASSWORD invalidates all old sessions, and any pod with the same secret accepts the cookie. Use time.time() for exp, constant-time compare, reject malformed tokens with 401. Keep cookie name dts_session, HttpOnly, SameSite=Strict, all routes and existing tests green; add tests: cookie from one app instance accepted by a second instance; rejected after DEMO_PASSWORD changes; tampered token rejected. Add optional env SESSION_SECRET (secretKeyRef optional: true) to the chart api Deployment.
```

## I — cloud-init и Terraform

```text
Create infra/cloud-init/user-data.yaml.tftpl (#cloud-config for Ubuntu 24.04: git make curl docker.io docker-compose-v2, user in docker group, runcmd: git clone of templated repo URL (private repo: token via Terraform templatefile, never hardcoded), then `make k8s-up` as the user, logs to /var/log/mts-k8s-up.log) and a rendered user-data.example.yaml for schema validation. infra/terraform/ for dmacvicar/libvirt ~> 0.8.1: one Ubuntu 24.04 cloud-image VM (4 vCPU, 8 GiB, 30 GiB) with cloud-init disk. variables.tf, outputs.tf, versions.tf (terraform >= 1.6), infra/README.md. Install terraform 1.9.8, run terraform init -backend=false && terraform validate; run cloud-init schema. Report actual results.
```

## K — проверки манифестов в CI

```text
Add CI job "manifests": helm template (stable and canary variants) validated by kubeconform v0.6.7 -strict -summary -kubernetes-version 1.31.0 with default + datreeio CRDs-catalog schema locations; validate deploy/monitoring/dashboard-configmap.yaml and prometheusrule.yaml. Job "dockerfiles": hadolint/hadolint-action@v3.1.0, failure-threshold error. Job shellcheck: shellcheck scripts/*.sh. Reproduce locally with kubeconform/hadolint binaries; fix only real errors.
```

## C2 — canary с анализом и автооткатом

```text
Rewrite scripts/canary.sh: for each weight step (default 10 50 100) helm upgrade --install sensor-canary with track=canary, canary.enabled=true, canary.weight=W (+ CANARY_HELM_ARGS), then analysis: (1) smoke.sh with X_CANARY=always; (2) Prometheus gate via PROM_URL: min(up{namespace="sensor",service="sensor-canary-api"}) == 1 and sum(rate(http_requests_total{...}[1m])) > 0 after a little load and ANALYSIS_WAIT_S. On any failure: weight 0, helm uninstall sensor-canary, print "ROLLBACK canary: <reason>", exit 1 — stable untouched. On success promote via deploy.sh and uninstall canary. Timestamps on each step. scripts/canary-fail-demo.sh: canary with --set existingSecret=sensor-secrets-wrong (pods start but smoke login fails) -> automatic rollback; show helm list and smoke stable.
```

Ручные правки после второй волны: окно `rate` увеличено до `[2m]` и ожидание до 75 с (при scrape 30 с окно 1m
давало пустой ответ — найдено в реальном прогоне); smoke не принимал точку в подписанной cookie; Ansible
переписан в обёртку над `make k8s-up` (версия модели дублировала логику и обходила SOPS);
секрет применялся без перезапуска подов — добавлен `rollout restart` при изменении.

## Третья волна (аудит жюри и доработки)

Общая преамбула всех сессий волны:

```text
Repo /workspace/mts-devops-case (MTS hackathon case 1, DevOps pipeline). Read README.md, Makefile, scripts/, deploy/ first. `make up` now = full path: scripts/k3s-install.sh (K3D=1 default: k3d cluster "mts", k3s v1.31.4, ingress-nginx 4.11.3, LB port 8081) -> secrets-init/apply (SOPS, Secret sensor-secrets in ns sensor with DEMO_PASSWORD, SESSION_SECRET) -> monitoring-install.sh (kube-prometheus-stack 65.1.1 release "mon" ns monitoring) -> build images ghcr.io/spar2/mts-devops-case/sensor-{gateway,web}:<sha>, k3d image import -> scripts/deploy.sh (helm release "sensor" ns sensor, chart deploy/helm/sensor-gateway, --atomic + scripts/smoke.sh). App via http://sensor.localtest.me:8081. Write ONLY files assigned to you, no git commands. Pin versions. Keep it small. When done print changed files and what you verified (only claim what you actually ran).

```

### auditA

```text
You are a strict hackathon jury member. Read /workspace/mts-devops-case/README.md (and skim docs/, Makefile). Do NOT modify any file, do not run git write commands. Audit the README against the MANDATORY template; headings must exist verbatim and in this order: "Название кейса"; "Описание проблемы"; "Цель работы"; "Состав команды (роли, опыт и навыки)"; "Архитектура/схема"; "Использованные инструменты с версиями"; "Как запустить (git clone …; make up)"; "Мониторинг и наблюдаемость"; "Безопасность"; "Использование LLM"; "Troubleshooting"; "Лицензия". Also check: every claim is backed by a file/log in repo, versions are concrete, mermaid diagram is valid and matches the code, resource requirements stated, no invented team biographies, no claims of jury approval, LLM section includes prompts, time saved, external API risks, how to verify without a key. Write findings as a numbered list (severity: blocker/major/minor, exact location, concrete fix) to /tmp/gp3/auditA.md. Be concrete and terse.

```

### auditB

```text
You are a strict DevOps hackathon jury member. Repo /workspace/mts-devops-case. Do NOT modify any repo file, no git writes. Case 1 requirements: (1) IaC: VM/local stand, k3s and network (Terraform/Ansible/cloud-init, netplan) — expected target stack OpenStack + Kubernetes but k3s/single-node allowed; (2) CI: build image and push to registry on push, scan (Trivy); (3) CD: Helm/Kustomize, blue-green or canary via ingress, rollback on failed release; (4) secrets via SOPS/Sealed Secrets/Vault with rotation described; (5) Prometheus+Grafana: at least one dashboard and one alert; (6) video <=5 min. General rules: Ubuntu reproduction with at most 3 commands (git clone, cd, make up) for the FULL solution, only open charts from public repos with versions, resources within 8-16 GB, small repo. Read the expert call transcript /home/box/agent-data/agents/debd819f-724d-4553-8015-d961ddac8370/attachments/bfa15027207fb7289dfe1c27d47ba1d518ff722232fbaf4de7fecb6d42a61a7c.txt (only DevOps case 1 and general rules; ignore SRE case 2) and extract nuances. Then audit the repo (README, Makefile, scripts/, deploy/, infra/, .github/workflows/ci.yml, docs/). Pay special attention to: whether the FULL solution (cluster+CD+monitoring) is reachable in 3 commands; jury access to images if GHCR packages are private; pinned versions; diagram accuracy; OpenStack fit (is there a path or explanation); netplan/cloud-init; resource numbers; repo size; anything that would fail on a clean Ubuntu 24.04 with docker (e.g. missing tools, sudo assumptions, /etc/hosts, ports). Write numbered findings (blocker/major/minor, location, concrete fix) plus a short list of transcript nuances to /tmp/gp3/auditB.md.

```

### M

```text
TASK M (alert delivery). Make Alertmanager deliver alerts to an in-cluster webhook sink so delivery is provable: add deploy/monitoring/alert-sink.yaml (Deployment+Service "alert-sink" in ns monitoring, image mendhak/http-https-echo:34 (pinned), port 8080, small resources, logs request bodies). In deploy/monitoring/values-kube-prometheus-stack.yaml configure alertmanager.config: route default receiver "null" but a child route matching alertname=~"SensorGateway.*" -> receiver "sensor-webhook" (webhook_configs url http://alert-sink.monitoring.svc:8080/alert, send_resolved true), group_wait 10s, group_interval 30s, repeat_interval 1h; keep Watchdog/InfoInhibitor going to null. Update scripts/monitoring-install.sh to kubectl apply alert-sink.yaml and wait for its rollout. Create scripts/alert-demo.sh: scales deploy sensor-api in ns sensor to 0, polls Prometheus alerts API WITHOUT port-forward via `kubectl -n monitoring exec prometheus-mon-kube-prometheus-stack-prometheus-0 -c prometheus -- wget -qO- http://127.0.0.1:9090/api/v1/alerts` every 10s up to 5 min until SensorGatewayDown is firing (print pending/firing transitions with timestamps), then checks Alertmanager API the same way (alertmanager-mon-kube-prometheus-stack-alertmanager-0 -c alertmanager, port 9093, /api/v2/alerts) and waits up to 90s until `kubectl -n monitoring logs deploy/alert-sink` contains SensorGatewayDown, prints PASS lines; ALWAYS restores replicas to 1 via trap and waits rollout; exit non-zero on failure. Also update deploy/monitoring/README.md. Validate: `helm template mon prometheus-community/kube-prometheus-stack --version 65.1.1 -f deploy/monitoring/values-kube-prometheus-stack.yaml` renders (repo may need `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts`), shellcheck scripts/alert-demo.sh scripts/monitoring-install.sh, kubectl apply --dry-run=client -f alert-sink.yaml (no cluster is running; do not create clusters). Only touch deploy/monitoring/*, scripts/monitoring-install.sh, scripts/alert-demo.sh.

```

### H

```text
TASK H (chart hardening). In deploy/helm/sensor-gateway: (1) api container securityContext: runAsNonRoot, runAsUser 65534, allowPrivilegeEscalation false, readOnlyRootFilesystem true (mount emptyDir at /tmp if needed), capabilities drop ALL, seccompProfile RuntimeDefault; pod automountServiceAccountToken false. (2) web (nginx:1.29-alpine runs as root on port 80): allowPrivilegeEscalation false, capabilities drop ALL add [CHOWN, SETUID, SETGID, NET_BIND_SERVICE, DAC_OVERRIDE] (whatever nginx master needs), seccompProfile RuntimeDefault; emptyDir for /var/cache/nginx and /var/run if you set readOnlyRootFilesystem (only if it works with stock nginx image; otherwise leave writable). (3) NetworkPolicy template (values networkPolicy.enabled default true): api pods accept ingress on 8000 only from web pods of the same release and from namespace monitoring (Prometheus scrape) — use namespaceSelector kubernetes.io/metadata.name: monitoring; web pods accept ingress on 80 only from namespace ingress-nginx. (4) PodDisruptionBudget for api and web (values pdb.enabled default true, maxUnavailable 1 — note with 1 replica minAvailable would block drains; use maxUnavailable: 1). Keep labels/selectors unchanged (canary release must still work: its web proxies to <release>-api). Validate: helm lint, helm template for stable and canary (--set track=canary --set canary.enabled=true --set canary.weight=10), and kubeconform if available at /tmp/bin/kubeconform (download v0.6.7 from github releases to /tmp/bin if missing) with -strict. Also run the api image locally with docker to confirm read-only root works: `docker build -t api-ro services/api && docker run --rm -d --name api-ro --read-only --tmpfs /tmp -e DEMO_PASSWORD=demo-stand-pass-123 -p 18000:8000 api-ro` then curl --noproxy '*' http://127.0.0.1:18000/ready, then docker rm -f api-ro. Same idea for web with --cap-drop ALL --cap-add the caps you chose (run `docker run --rm -d --name web-t --cap-drop ALL --cap-add ... -p 18080:80 <built web image>`; curl / should return 200), then remove. Only touch deploy/helm/sensor-gateway/.

```

### E

```text
TASK E (live CD proof in GitHub Actions). Create .github/workflows/e2e.yml: name e2e; on push to main (paths-ignore: '**.md', 'docs/**') and workflow_dispatch; concurrency group e2e cancel-in-progress. One job on ubuntu-24.04, timeout-minutes 40, permissions contents read: checkout; run exactly `make up` (this is the jury path; it installs helm/kubectl/k3d itself via scripts/k3s-install.sh with sudo, runners have passwordless sudo and docker; sensor.localtest.me resolves to 127.0.0.1 via public DNS, but add `echo "127.0.0.1 sensor.localtest.me grafana.localtest.me" | sudo tee -a /etc/hosts` as a safety step and note it); then run demo steps each as separate named steps: `make k8s-canary-fail`, `make k8s-rollback-demo`, `make k8s-rotate-demo`, `make k8s-alert-demo` (alert demo script scripts/alert-demo.sh is being written by another session; reference the make target anyway), then `make k8s-canary` with env ANALYSIS_WAIT_S=75; finally a step `if: always()` that collects diagnostics (kubectl get pods -A, helm list -A, kubectl -n sensor describe pods | tail -n 100, kubectl -n monitoring get pods) and a step `if: always()` that runs `make down`. Use env INGRESS_PORT=8081 at job level. Do NOT run anything locally that creates clusters (box has low memory). Validate the YAML with actionlint v1.7.3 (download binary from github releases into /tmp/bin) and fix all findings. Only create .github/workflows/e2e.yml.

```

### R

```text
Отредактируй README.md в этом репозитории (только README.md, docs/demo-script.md). Заголовки верхнего уровня и их порядок НЕ менять. Исправить по аудиту /tmp/gp3/auditA.md и /tmp/gp3/auditB.md (прочитай оба). Обязательно:
- удалить фразу о том, что эксперты/жюри допустили Compose или что-либо подтвердили;
- ресурсы: честно — ingress-nginx и kube-prometheus-stack частично без limits, указать запросы/лимиты чарта приложения из deploy/helm/sensor-gateway/values.yaml;
- rate-limit: лимит на процесс API, ключ — адрес пира (nginx), а не клиента;
- версии: k3d v5.8.3, k3s v1.31.4+k3s1, React и Vite — взять точные из apps/web/package.json, Trivy action v0.36.0 / engine v0.70.0, shellcheck, hadolint, kubeconform 0.6.7, actionlint;
- PromQL примеры с namespace="sensor";
- заметка: проект ingress-nginx объявлен архивным (2026-03-24), используется закреплённая версия 4.11.3;
- в Безопасности: securityContext (readOnlyRootFilesystem, drop ALL, seccomp RuntimeDefault, без токена SA), NetworkPolicy (вход к API только от web и ingress-nginx, к web только от ingress-nginx; проверяется `make k8s-netpol-check` в e2e на GitHub; в песочницах без ipset контроллер k3s не стартует и политика не применяется — честно), PDB, SBOM (CycloneDX/SPDX артефакт в CI на main), токен k3s остаётся в user-data/ISO cloud-init;
- Мониторинг: alert-sink (webhook, mendhak/http-https-echo:34) и `make k8s-alert-demo`;
- новые make-цели: k8s-canary-fail, k8s-rotate-demo, k8s-alert-demo, k8s-netpol-check; e2e workflow (.github/workflows/e2e.yml, матрица k3d и нативный k3s);
- раздел «Что не проверено»: terraform apply не выполнялся (только validate + cloud-init schema), видео не записано (требования: ≤5 мин, монтаж допустим, без сгенерированных кадров).
Не выдумывай фактов, не пиши TODO. docs/demo-script.md: привести под `make up` и новые цели.

```

Сессия R (правка README) зависла без результата больше 30 минут и была остановлена; README по аудитам правил человек.
Ручные правки третьей волны: пробы web перестали ходить в API (падение API перезапускало web); проверка NetworkPolicy
вынесена в `scripts/netpol-check.sh` (в песочнице без ipset политика не применяется — найдено прогоном); метрический гейт canary
переведён на метрики ingress-nginx, а недоступный Prometheus теперь откатывает canary (раньше `pgrep -f` находил сам себя,
port-forward не поднимался и гейт молча пропускался); ожидание появления target canary в Prometheus; пароль Grafana в SOPS;
kubeconfig 600; алерты NoReplicas/PodRestarts вместо бесполезного SlowProbe; resolved в alert-demo; откат первой установки через uninstall.

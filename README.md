# Облачный DevOps-конвейер: от репозитория до production-Kubernetes за 3 команды

## Название кейса

Кейс 1 хакатона МТС «Облачный DevOps-конвейер: от репозитория до production-Kubernetes за 3 команды».

Демо-служба `sensor-gateway` (FastAPI) и веб-интерфейс из трёх окон.

Что есть на самом деле:

- **CI (GitHub Actions, `ci.yml`).** На каждый push и pull request: линт, тесты, проверки манифестов, IaC (Terraform, Ansible, cloud-init, Trivy config), сборка, Trivy образов. На уровне workflow `permissions: contents: read`. Job `images` (pull request и push не в `main`) собирает и сканирует, без push и без `packages: write`. Job `images-publish` (только push в `main`) поднимает `packages: write`, пушит образы в приватный GHCR и кладёт SBOM. Concurrency `ci-${{ github.ref }}`: push в одну ветку ждёт в очереди без отмены, чтобы прогоны не перетирали `:latest` не по порядку; pull request отменяет предыдущий прогон. Все `uses:` закреплены по SHA коммита. Локально: `make lint` и `make test` — jobs `lint`, `api`, `web`, `helm`, `manifests`, `dockerfiles`, `shellcheck` и `ruff` из job `llm`. Не входят job `images`, `images-publish` и job `iac` (раздел «CI локально»).
- **CD.** Выкладка в кластер идёт командами `make up`, `make k8s-deploy` и `make k8s-canary`: Helm `--atomic`, smoke, canary через ingress-nginx с PromQL-гейтом и автооткатом. Stable собирается из текущего коммита. `make k8s-canary` собирает тот же исходник отдельным тегом `<sha>-canary`.
- **e2e в Actions (`e2e.yml`).** На pull request в `main` (кроме правок только `*.md`/`docs/`) прогоняется только k3d. На push в `main` с тем же фильтром и вручную через `workflow_dispatch` — оба варианта, k3d и нативный k3s. Устаревший прогон того же PR отменяется; прогон `main` не прерывается (группа `e2e-${{ github.ref }}`). Секретов workflow нет, `permissions: contents: read`, образы собираются на раннере. `make status` при `CI=true` пароли не печатает. Шаг после `make up` и шаг после ротации читают Secret и регистрируют `::add-mask::`.
- **Без CD-деплоя из Actions.** Отдельного деплоя в постоянный кластер из Actions нет: у проекта нет постоянного кластера, доступного GitHub.

## Описание проблемы

Проверяющему нужно у себя на Ubuntu короткой командой поднять сервис и увидеть весь конвейер: сборку образа,
выкладку, откат неудачного релиза, секреты вне git и наблюдаемость. Полный продукт для этого слишком большой,
поэтому в репозитории одна служба и три окна (`/`, `/login`, `/service`). Расчёты, очереди, БД и остальной
контур платформы сюда сознательно не входят.

## Цель работы

Воспроизводимый конвейер из открытых инструментов с зафиксированными версиями, где каждое требование кейса
можно проверить командой и где есть лог реальной проверки.

### Требования кейса → реализация → проверка

| Требование | Где лежит | Как проверить | Статус проверки |
| --- | --- | --- | --- |
| Запуск ≤ 3 командами | `Makefile` (`make up`) | `git clone … && cd mts-devops-case && make up` | Проверено: свежий клон e0fe907 на box без кластера, `make up` за 2 мин 0 с (smoke: вход, probe, 401 без cookie, `/metrics`); повторный `make k8s-up K3D=1` идемпотентен (1 мин 11 с). Тот прогон читал тело `/metrics` через ingress. Текущий `scripts/smoke.sh` ждёт снаружи 403 от nginx web или 404 и читает `service_up` через `kubectl exec` в под API; этот вариант на кластере не перепрогонялся. Тот же путь `make up` — в e2e GitHub Actions: k3d на pull request в `main`, k3d и нативный k3s на push в `main` и по `workflow_dispatch` |
| IaC: кластер | `scripts/k3s-install.sh`, `infra/ansible/site.yml` | `make k8s-up` / `ansible-playbook -i infra/ansible/inventory.ini infra/ansible/site.yml` | k3d: свежий клон на box и e2e; нативный k3s (`make up K3D=0`): только e2e на `ubuntu-24.04`. Лог `docs/k8s-up-log.md`. Полный прогон плейбука в репозитории не залогирован; syntax-check — job `iac` (ansible-core 2.17.14) |
| IaC: ВМ | `infra/cloud-init/`, `infra/terraform/` (libvirt, lock 0.8.3) | job `iac`: `terraform fmt -check`, `init -backend=false`, `validate`, `cloud-init schema`; живой `terraform apply` (`vm_memory_mib`, `vm_vcpu`, `run_make_up`) и `terraform destroy` | Job `iac` зелёный на GitHub (pull request #3, run 39006928822, коммит `82bbe4f`) и локально на той схеме (Terraform 1.9.8, cloud-init 26.1, схемы `Valid`). Живой apply на box 2026-10-17 шёл с `github_token` (переменной больше нет): 2048 МиБ / 2 vCPU, `run_make_up=false`, cloud-init `status: done`, клон и пакеты, `vm_ip` совпал с DHCP. `make up` в госте не запускался. Лог `docs/iac-apply-log.md`. Новая схема (HTTPS без токена или `github_deploy_key_path`) на ВМ не применялась |
| CI: линт, тесты, сборка | `.github/workflows/ci.yml` | вкладка Actions | Зелёный прогон на GitHub (jobs lint, api, web, helm, manifests, dockerfiles, shellcheck, llm, iac, images) до выноса push в `images-publish`. Это разделение, pin `uses:` по SHA и concurrency `ci-<ref>` на GitHub не перепроверялись. Job `iac` зелёный на GitHub (pull request #3) и воспроизведён локально |
| Сканирование образов | job `images` (не `main`) и job `images-publish` (push в `main`); job `iac` (config: чарт, Dockerfile, Terraform). `trivy-action` v0.36.0 по SHA `ed142fd0673e97e23eac54620cfb913e5ce36c25` (Trivy v0.70.0), HIGH/CRITICAL; SBOM (anchore/sbom-action) в `images-publish` | Actions → images или images-publish, и iac | Образы: CVE (Starlette, OpenSSL в alpine) исправлены, прогон зелёный (тогда шаг был в job `images`). Config: локально Trivy 0.70.0, чарт и Terraform без HIGH/CRITICAL; DS-0002 nginx-образа — `apps/web/.trivyignore` |
| Публикация в registry | job `images-publish`: push в `ghcr.io/spar2/mts-devops-case/*` только из `main`, право `packages: write` только у этого job. На pull request job `images` без push | Actions → images-publish → Push images | Push был в зелёном прогоне job `images`. Job `images-publish` на GitHub не перепроверялся |
| Проверка манифестов | `scripts/lint-manifests.sh` (kubeconform 0.6.7: stable, canary, два манифеста мониторинга), hadolint 2.12.0, shellcheck 0.10.0 | `make lint` | Проверено локально: `make lint` код 0. Сломанный YAML и скрипт с ошибкой shellcheck дают ненулевой код (правки откачены). Job `manifests` вызывает тот же скрипт |
| CD: Helm + откат | `deploy/helm/sensor-gateway` (RollingUpdate `maxUnavailable: 0`, `preStop`), `scripts/deploy.sh` (`--atomic` + smoke + `helm rollback` / `uninstall`) | `make k8s-rollback-demo`; без кластера — `scripts/test-deploy-rollback.sh` в `make lint` | Проверено на кластере: битый тег → откат `--atomic`; провал smoke → `helm rollback` (лог `docs/cd-demo-log.md`). С `preStop` полный прогон с нуля на box 2026-10-17: `make up`, canary, canary-fail, rollback-demo, alert-demo — PASS. Ветка «нет ревизий / одна ревизия / ошибка самого rollback» на кластере этим прогоном не покрыта: её гоняет `test-deploy-rollback.sh` (заглушки helm/kubectl) |
| CD: canary через ingress | `scripts/canary.sh`: тег `CANARY_TAG` (по умолчанию `<sha>-canary`), импорт в k3d-кластер `CLUSTER` (по умолчанию `mts`), `/ready` отдаёт тег (`version` и `X-App-Version`), вес 10→50→100, smoke этой версии, доля ответов и доля canary-Ingress в допуске веса, PromQL (`up`, трафик, 5xx; NaN/Inf — откат), promote: stable → rollout → вес 0 → ingress → uninstall | `make k8s-canary` | Локально проверены разбор NaN/Inf, границы веса и парсер версии (`CANARY_SELF_TEST=1 ./scripts/canary.sh`), `bash -n`, shellcheck 0.10.0, `helm lint`/`template`, `make lint`, pytest `/ready`. Кластер не поднимался, живого прогона нового гейта нет. `docs/cd-demo-log.md` — прежний скрипт на кластере (тот же тег, что stable, без проверки веса, uninstall сразу после promote): успешный canary с promote и провальный с автооткатом, stable не задет |
| Сессии не теряются между stable и canary | подписанная cookie (HMAC) в `services/api/app/main.py` | тесты + запрос с cookie от stable в canary | Проверено: 200 на canary с cookie, выданной stable |
| Секреты вне git | SOPS 3.9.2 + age 1.2.1, `scripts/secrets-*.sh`, `deploy/secrets/README.md` | `scripts/secrets-rotate-check.sh` | Лог 2026-10-17: старый пароль и cookie → 401, новый → 200 (`docs/secrets-rotation-log.md`). Без паузы перед SIGTERM на 1 реплике скрипт ловил 502; с `preStop` и ожиданием ухода старых подов в `secrets-rotate.sh` — 3 прогона подряд PASS на box 2026-10-17 |
| Мониторинг: дашборд | `deploy/monitoring/` (kube-prometheus-stack 65.1.1) | Grafana → дашборд `sensor-gateway` | Проверено в k3d, скриншот `docs/img/grafana-sensor-gateway.png` |
| Мониторинг: алерт | `deploy/monitoring/prometheusrule.yaml` | `kubectl -n sensor scale deploy sensor-api --replicas=0` | Проверено: `SensorGatewayDown` firing в Prometheus и в Alertmanager (`docs/monitoring-alert-proof.md`, скриншоты) |
| Сеть ВМ (netplan) | `infra/cloud-init/network-config.yaml` → `libvirt_cloudinit_disk.network_config` | `cloud-init schema` (job `iac`); в госте `sudo netplan get`, `ip addr` | Схема валидна (cloud-init 26.1, job `iac`). На ВМ 2026-10-17: DHCP, `match: en*`, `ens3` получил `192.168.122.188/24`; адрес совпал с `terraform output vm_ip` и арендой libvirt |
| Безопасность подов | securityContext, NetworkPolicy (ingress и egress) в чарте | `make k8s-netpol-check` | Ingress NetworkPolicy проверена в e2e на GitHub (чужой namespace → BLOCKED, web → API → REACHED). Egress (web → DNS и api, у api исходящих нет) в кластере не прогонялся |
| Отказоустойчивость stable | чарт: api и web по 2 реплики, PDB `minAvailable: 1`, HPA CPU 70% (min 2, max 4). Canary (`track=canary`): 1 реплика, без PDB и HPA | `helm template` stable и canary, `make lint` | Кластер не поднимался. `scripts/canary.sh`, `rollback-demo.sh` и `secrets-rotate-check.sh` на ровно одну реплику не завязаны |
| Доставка алерта | Alertmanager → webhook `alert-sink` | `make k8s-alert-demo` | Проверено: firing → webhook → resolved (e2e и box) |
| LLM: генерация конфигов с фиксацией промптов | `llm/`, `scripts/llm-*.sh`, `docs/llm/` | `make llm-up && make llm-gen`, `make llm-test` | Повтор 2026-10-17 (`make llm-up`, `-t 4`): из трёх фраз в `docs/llm/model-choice.md` с первой попытки valid одна (5xx, 16.88 с). Задержка invalid, attempts 2, 51.11 с. Память valid со 2-й, 104.27 с. Explain valid, 66.67 с. Оба прогона в `docs/llm/examples/runs.jsonl`. Job `llm` в CI |
| Видео ≤ 5 мин | `docs/demo-script.md` | — | Сценарий готов, ролик снимает команда |

## Состав команды (роли, опыт и навыки)

| Роль | Зона ответственности в репозитории | Навыки, которые применены в решении |
| --- | --- | --- |
| Веб | Три окна: лендинг, вход, служба (`apps/web`) | React 19, Vite 8, nginx |
| DevOps | CI, образы, Helm-чарт, k3s/k3d, canary, SOPS, IaC (`.github/`, `deploy/`, `scripts/`, `infra/`) | GitHub Actions, Docker/BuildKit, Trivy, Helm, Kubernetes, ingress-nginx, SOPS/age, Ansible, Terraform, cloud-init |
| SRE | Метрики, дашборд, алерт, доставка алерта (`deploy/monitoring/`) | Prometheus/PromQL, Grafana, Alertmanager, kube-prometheus-stack |

Имена и личный опыт участников команда указывает сама при сдаче; выдуманных биографий в репозитории нет.

## Архитектура/схема

```mermaid
flowchart LR
  dev[git push main] --> ci[GitHub Actions: ruff, pytest, npm build, kubeconform, hadolint, shellcheck, IaC, docker build, Trivy]
  ci -->|push только из main| ghcr[(ghcr.io/spar2/mts-devops-case)]
  ghcr -.->|опционально: make ghcr-secret + k8s-deploy-ghcr| ns
  build[make k8s-images: docker build + k3d image import] -->|путь по умолчанию| ns
  tf[Terraform libvirt + cloud-init] -.->|ВМ Ubuntu 24.04| k3s
  subgraph k3s[k3s v1.31.4, один узел]
    ing[ingress-nginx 4.11.3]
    subgraph ns[namespace sensor]
      web[sensor-web nginx] --> api[sensor-api FastAPI]
      cweb[sensor-canary-web] --> capi[sensor-canary-api]
    end
    sec[Secret sensor-secrets из SOPS+age] -.-> api
    sec -.-> capi
    subgraph mon[namespace monitoring]
      prom[Prometheus] --> graf[Grafana: дашборд sensor-gateway]
      prom --> am[Alertmanager] -->|webhook| sink[alert-sink]
    end
    prom -->|ServiceMonitor /metrics| api
    prom -->|ServiceMonitor /metrics| capi
  end
  cd[deploy.sh / canary.sh: helm --atomic, smoke, PromQL-гейт, rollback] --> ns
  cd -->|PromQL: up, трафик, 5xx и доля canary| prom
  prom -->|ServiceMonitor| ing
  user[Браузер] --> ing
  ing -->|stable| web
  ing -->|canary-weight или X-Canary: always| cweb
```

- Compose-режим (`make demo`): браузер → nginx `web` (127.0.0.1:8080) → `api:8000`. Nginx отдаёт интерфейс и
  проксирует `/api`, `/health`, `/ready`. На `/metrics` отвечает 403 и в API не ходит.
- В Kubernetes nginx-конфиг web подменяется ConfigMap'ом чарта: каждый релиз проксирует в свой Service `<release>-api`
  и передаёт API `X-Real-IP`, который выставил ingress-nginx. Клиентский `X-Forwarded-For` web в API не пересылает: его можно подделать.
  На `/metrics` nginx web отвечает 403. Ingress ведёт только на Service web и этот путь отдельно не закрывает.
  Prometheus читает `/metrics` Service API через ServiceMonitor, минуя ingress.
- Сессия — подписанная cookie `sensor_session` (HMAC-SHA256, `HttpOnly`, `SameSite=Strict`). Ключ выводится из
  `SESSION_SECRET` и `DEMO_PASSWORD`, поэтому stable и canary принимают одну cookie, а ротация пароля отзывает все сессии.

## Использованные инструменты с версиями

| Инструмент | Версия |
| --- | --- |
| Python / FastAPI / Starlette / Uvicorn / prometheus-client | 3.12 (`python:3.12-slim-bookworm`) / 0.143.3 / 1.8.0 / 0.34.0 / 0.26.0 |
| Node.js / Vite / React | 24 (`node:24-bookworm-slim`) / 8.3.4 / 19.3.1 (из `package-lock.json`) |
| nginx | 1.29-alpine + `apk upgrade` |
| Docker / Compose | Docker 24+ с BuildKit / Compose V2 (проверено 2.30.3) |
| k3s | v1.31.4+k3s1, traefik отключён |
| k3d (режим по умолчанию) | v5.8.3, sha256 в `scripts/k3s-install.sh` |
| kubectl | v1.31.4, sha256 в `scripts/k3s-install.sh` |
| Helm | v3.16.3, sha256 в `scripts/k3s-install.sh` (те же суммы архива, что в `scripts/lint-manifests.sh`) |
| ingress-nginx | чарт 4.11.3, https://kubernetes.github.io/ingress-nginx. Проект объявлен архивным 2026-03-24, версия зафиксирована и работает; на замену стоит смотреть Gateway API |
| kube-prometheus-stack | чарт 65.1.1, https://prometheus-community.github.io/helm-charts (Prometheus 2.54.1, Grafana 11.2.1, Alertmanager 0.27.0) |
| SOPS / age | 3.9.2 / 1.2.1 |
| Ansible | ansible-core 2.17.14 (syntax-check в job `iac`; полный прогон плейбука в репозитории не залогирован) |
| Terraform / провайдер | 1.9.8 / dmacvicar/libvirt 0.8.3. Lock-файл `infra/terraform/.terraform.lock.hcl` (в `versions.tf`: `>= 1.6`, `~> 0.8.1`). На box при живом apply ещё libvirt 11.3.0 и QEMU 10.0.13 |
| cloud-init | На run 39006928822: 26.1-0ubuntu1~24.04.1 (пакет ubuntu-24.04 без пина, версия печатается в лог). Схема: `user-data.example.yaml` и `network-config.yaml`; `user-data.yaml.tftpl` не подаётся. В госте Ubuntu 24.04.5 — `26.1-0ubuntu1~24.04.1`, `status: done`. Схема на хосте прогона — 25.1.4. |
| Локальная LLM (опц.) | llama.cpp server `b11681`, модель Ternary-Bonsai-2-4B Q2_0 (Apache-2.0), promtool из `prom/prometheus:v2.54.1` |
| GitHub Actions | `ubuntu-24.04`, ruff 0.8.4, ansible-core 2.17.14, cloud-init (пакет ubuntu-24.04), kubeconform 0.6.7, shellcheck 0.10.0, Trivy v0.70.0. `uses:` по SHA коммита (в скобках тег, с которого снят SHA): checkout `11d5960a326750d5838078e36cf38b85af677262` (v4.4.0), setup-python `a26af69be951a213d495a4c3e4e4022e16d87065` (v5.6.0), setup-node `49933ea5288caeca8642d1e84afbd3f7d6820020` (v4.4.0), setup-buildx-action `8d2750c68a42422c14e847fe6c8ac0403b4cbd6f` (v3.12.0), build-push-action `10e90e3645eae34f1e60eeb005ba3a3d33f178e8` (v6.19.2), login-action `c94ce9fb468520275223c153574b00df6fe4bcc9` (v3.7.0), trivy-action `ed142fd0673e97e23eac54620cfb913e5ce36c25` (v0.36.0, annotated, SHA коммита), setup-terraform `dfe3c3f87815947d99a8997f908cb6525fc44e9e` (v4.0.1, Terraform 1.9.8), setup-helm `1a275c3b69536ee54be43f2070a358922e12c8d4` (v4.3.1), sbom-action `55dc4ee22412511ee8c3142cbea40418e6cec693` (v0.17.8), hadolint-action `54c9adbab1582c2ef04b2016b760714a4bfde3cf` (v3.1.0, hadolint 2.12.0, порог error) |
| Приёмник алертов | `mendhak/http-https-echo:34` |

Только открытые чарты из публичных репозиториев. Чарты и бинарники конвейера запинены. cloud-init в CI — пакет архива ubuntu-24.04 без пина.

`scripts/k3s-install.sh` перед первой установкой сверяет sha256 скачанного файла (уже стоящий бинарь нужной версии повторно не качается и не сверяется). Суммы сняты 2026-10-17 с официальных файлов: Helm — `https://get.helm.sh/helm-v3.16.3-linux-<arch>.tar.gz.sha256sum` (amd64 `f5355c79190951eed23c5432a3b920e071f4c00a64f75e077de0dd4cb7b294ea`, arm64 `5bd34ed774df6914b323ff84a0a156ea6ff2ba1eaf0113962fa773f3f9def798`); kubectl — `https://dl.k8s.io/release/v1.31.4/bin/linux/<arch>/kubectl.sha256` (amd64 `298e19e9c6c17199011404278f0ff8168a7eca4217edad9097af577023a5620f`, arm64 `b97e93c20e3be4b8c8fa1235a41b4d77d4f2022ed3d899230dbbbbd43d26f872`); k3d — строки `_dist/k3d-linux-amd64` и `_dist/k3d-linux-arm64` из `https://github.com/k3d-io/k3d/releases/download/v5.8.3/checksums.txt` (amd64 `dbaa79a76ace7f4ca230a1ff41dc7d8a5036a8ad0309e9c54f9bf3836dbe853e`, arm64 `0b8110f2229631af7402fb828259330985918b08fefd38b7f1b788a1c8687216`). `<arch>` — `amd64` или `arm64`.

### Ресурсы

| Режим | RAM | CPU | Диск |
| --- | --- | --- | --- |
| `make demo` (Compose) | до 2 ГБ | 1–2 vCPU | ~1 ГБ образов |
| `make up` (k3s + мониторинг) | 8 ГБ достаточно (весь стек около 3 ГБ), 16 ГБ с запасом | 2–4 vCPU | ~10 ГБ |
| `make llm-up` (опц.) | пик RSS 1.66 ГБ (2B-вариант ~0.7 ГБ) | 4–6 vCPU с AVX2 | 1.2 ГБ весов + 0.1 ГБ образ |
| ВМ из `infra/terraform` | 8 ГиБ по умолчанию (`vm_memory_mib=8192`); живой прогон — 2048 МиБ | 4 vCPU по умолчанию; живой прогон — 2 | 30 ГиБ |

Лимиты: API — requests 50m/128Mi, limits 500m/256Mi; web — 25m/64Mi и 200m/128Mi (`values.yaml`). HPA stable (`autoscaling/v2`, CPU 70%, min 2, max 4) считает utilization от этих CPU requests. У canary HPA нет. У компонентов kube-prometheus-stack
лимиты заданы в `values-kube-prometheus-stack.yaml`. У alert-sink — 10m/32Mi и 100m/64Mi (`alert-sink.yaml`). У ingress-nginx ресурсы не задаются (значения чарта по умолчанию, без limits).

## Как запустить (git clone …; make up)

Подготовка чистой Ubuntu 22.04/24.04 (один раз, затем перелогиниться):

```bash
sudo apt-get update && sudo apt-get install -y git make curl openssl python3 docker.io && sudo usermod -aG docker "$USER"
```

Нужно: Git, `make`, Docker (пользователь в группе `docker`), `curl`, `openssl`, `python3`, `sudo`
(только чтобы положить pinned helm/kubectl/k3d в `/usr/local/bin` и при необходимости дописать `/etc/hosts`).
Ресурсы: 8 ГБ RAM, 2–4 vCPU, ~10 ГБ диска. Порт `8081` на хосте должен быть свободен.

Репозиторий приватный: жюри клонирует его под GitHub-аккаунтом, которому выдан доступ (HTTPS с токеном или SSH-ключ).

```bash
git clone https://github.com/Spar2/mts-devops-case.git
cd mts-devops-case
make up
```

`make up` поднимает **полное решение** (~5 минут на чистой машине):

1. `scripts/k3s-install.sh` — проверяет зависимости, ставит pinned helm v3.16.3 / kubectl v1.31.4 / k3d v5.8.3
   (sha256 архива или бинаря), создаёт k3d-кластер `CLUSTER` (по умолчанию `mts`, k3s v1.31.4 в Docker), ставит ingress-nginx 4.11.3 и ждёт готовности его admission webhook.
   Если кластер с этим именем уже есть, скрипт его не удаляет и не пересоздаёт: в stderr предупреждение, что образ, проброс порта и `K3D_EXTRA_ARGS` этого запуска не применяются;
2. `scripts/secrets-init.sh` + `secrets-apply.sh` — ставит sops/age, генерирует ключ age этой машины и два зашифрованных Secret: `sensor-secrets` (пароль входа, ключ сессий) и `grafana-admin`;
3. сборка образов из исходников и `k3d image import` (до мониторинга — ниже пик RAM) — **доступ к приватному GHCR не нужен**;
4. `scripts/monitoring-install.sh` — kube-prometheus-stack 65.1.1, дашборд, правила алертов, приёмник алертов `alert-sink`;
5. `scripts/deploy.sh` — Helm-релиз `sensor` (`--atomic`) и smoke-проверка; при провале — `helm rollback`, а если ревизия одна или её нет — `helm uninstall`. Ошибка history не обрывает скрипт до этой команды; ошибка самого rollback/uninstall даёт код 1 и строку `error:`;
6. `make status` — печатает адреса. Пароль в вывод не входит: рядом команда `kubectl`, само значение — только `SHOW_SECRETS=1 make status`. При `CI=true` значение не печатается и эта переменная его не включает.

Результат:

- приложение: http://sensor.localtest.me:8081 — логин `demo`; пароль: `SHOW_SECRETS=1 make status` (без флага в выводе команда `kubectl -n sensor get secret sensor-secrets … | base64 -d`);
- Grafana: http://grafana.localtest.me:8081 — логин `admin`, случайный пароль из SOPS-секрета `grafana-admin` так же (`SHOW_SECRETS=1` или `kubectl` из вывода `make status`); дашборд `sensor-gateway`.

`*.localtest.me` публично резолвится в 127.0.0.1; если DNS этого не делает, скрипт сам дописывает `/etc/hosts`.

Демонстрации на поднятом стенде (каждая — одна команда, все прогоняются в GitHub Actions, job `e2e`):

```bash
make k8s-canary          # образ <sha>-canary, вес 10→50→100: версия /ready, доля веса, PromQL (up, трафик, 5xx), promote через вес 0
make k8s-canary-fail     # canary с неверным секретом → автоматический откат, stable не задет
make k8s-rollback-demo   # битый тег образа → helm --atomic откатывает релиз, печатается helm history
make k8s-rotate-demo     # ротация пароля: старый пароль и старая cookie → 401, новый → 200
make k8s-alert-demo      # API выключается → SensorGatewayDown firing → Alertmanager → webhook alert-sink → API обратно → resolved
make k8s-netpol-check    # NetworkPolicy: под из чужого namespace не достаёт API, web достаёт (нужен работающий контроллер политик)
make down                # demo-down, если есть .env; K3D=1: ещё k3d cluster delete $(CLUSTER) (по умолчанию mts); K3D=0: снять релизы sensor-canary, sensor, mon, k3s не удаляет
```

Другие режимы:

- `make demo` — лёгкое демо без Kubernetes (Docker Compose, http://127.0.0.1:8080, пароль из `.env.example`), до 2 ГБ RAM.
- `make up K3D=0` — нативный k3s на хосте (ВМ, OpenStack-инстанс), ingress на `:80`. Проверено в GitHub Actions на Ubuntu 24.04.
- `ansible-playbook -i infra/ansible/inventory.ini infra/ansible/site.yml` — плейбук-обёртка над `make k8s-up`
  (локальный, `connection: local`; логика не дублируется).
- ВМ: `infra/README.md` — Terraform (libvirt) + cloud-init + netplan. По умолчанию внутри ВМ выполняется `make up K3D=0` (`run_make_up=true`). Клон на ВМ без GitHub-токена (публичный HTTPS) либо по deploy-key (`github_deploy_key_path`). Живой прогон на box — старая схема с `github_token` и `run_make_up=false`, лог `docs/iac-apply-log.md`. Повторный apply после удаления токена не делался.
- Образы из GHCR (их пушит CI из `main`): пакеты приватные, как и репозиторий. `GHCR_USER=… GHCR_TOKEN=<PAT read:packages> make ghcr-secret`
  создаёт pull-secret `ghcr`, затем `make k8s-deploy-ghcr TAG=<sha>`. Создание секрета и шаблон чарта проверены, вытягивание из
  приватного GHCR в кластере — нет. Путь по умолчанию (локальная сборка) от GHCR не зависит.

### CI локально

`make lint` и `make test` повторяют jobs `lint`, `api`, `web`, `helm`, `manifests`, `dockerfiles`, `shellcheck` и `ruff check llm`. Не входят job `images` и `images-publish` (сборка, Trivy образов, push, SBOM), job `iac` и pytest/promtool job `llm` (`make llm-test`).

```bash
make lint
make test
```

`make lint` — jobs `lint`, `helm`, `manifests`, `dockerfiles`, `shellcheck` и `ruff check llm` из job `llm`, плюс локальный сценарий отката `scripts/test-deploy-rollback.sh` (в CI job `shellcheck` его нет: workflow вызывает только `make lint-shellcheck`):

- ruff 0.8.4: `ruff check services/api` и `ruff check llm`. Бинарь этой версии из PATH, иначе образ `ghcr.io/astral-sh/ruff:0.8.4`;
- Helm v3.16.3: `helm lint` и `helm template` чарта (`deploy/helm/sensor-gateway`, namespace `sensor`);
- kubeconform 0.6.7: `scripts/lint-manifests.sh` (его же вызывает job `manifests`) — stable, canary (`track=canary`, вес 10, api-versions `monitoring.coreos.com/v1` и `monitoring.coreos.com/v1/ServiceMonitor`) и файлы `deploy/monitoring/dashboard-configmap.yaml`, `prometheusrule.yaml`. Флаги: `-strict -summary -kubernetes-version 1.31.0`, схемы default и CRDs-catalog;
- hadolint 2.12.0 с `--failure-threshold error` для `services/api/Dockerfile` и `apps/web/Dockerfile` (в CI это `hadolint/hadolint-action` `54c9adbab1582c2ef04b2016b760714a4bfde3cf`, тег v3.1.0);
- shellcheck 0.10.0 для `scripts/*.sh`;
- `scripts/test-deploy-rollback.sh`: `deploy.sh` после проваленного smoke. Заглушки `helm` и `kubectl` в PATH, HTTP 500 на localhost, кластер не поднимается. `kubectl` отвечает только на `exec` чтения `/metrics` пода `sensor-api` (так smoke проверяет тело метрик) и печатает `service_up 1` и тип гистограммы; любой другой вызов — код 1. Проверяются пустая история, одна ревизия, битый JSON, объект вместо списка, ненулевой код `helm history`, откат при двух ревизиях и ненулевой код с текстом `error: helm rollback` / `error: helm uninstall`, если сама команда отката падает.

Если ruff, hadolint или shellcheck нужной версии нет в PATH, нужен Docker (`hadolint/hadolint:v2.12.0`, `koalaman/shellcheck:v0.10.0`). Helm и kubeconform без sudo ставятся в `~/.local/bin`, архив сверяется sha256 (суммы в `scripts/lint-manifests.sh`). kubeconform скачивает JSON Schema, нужен исходящий HTTPS.

`make test` — job `api` (pytest в `services/api`) и job `web` (`npm ci && npm run build`). Остальное из job `llm` (pytest и promtool) — `make llm-test` и `python llm/llm_gen.py validate-rule deploy/monitoring/prometheusrule.yaml`.

Проверено локально: `make lint` завершился с кодом 0. Невалидный YAML в `deploy/monitoring/prometheusrule.yaml` и синтаксическая ошибка в `scripts/smoke.sh` дают ненулевой код; оба файла возвращены как были. На этой ветке `make lint` снова код 0, включая `scripts/test-deploy-rollback.sh`.

### Как работает CD

- `scripts/deploy.sh TAG` — `helm upgrade --install --atomic --wait --timeout 3m`; если поды не стали ready, Helm откатывает
  релиз сам. Затем `scripts/smoke.sh` (`/ready`, снаружи `/metrics` 403 от nginx web или 404, тело метрик через `kubectl exec` в под API, 401 без cookie, вход, `/api/v1/service`, probe). При провале smoke
  число ревизий берётся из `helm history -o json`. Ошибка history, пустой вывод, битый JSON и не-список считаются нулём ревизий и не обрывают скрипт до отката.
  Ноль или одна ревизия — `helm uninstall sensor` (предыдущей нет). Две и больше — `helm rollback sensor 0`. Если uninstall или rollback сам завершился с ошибкой, скрипт печатает `error: helm uninstall … failed` или `error: helm rollback … failed` и выходит с кодом 1. Успешный откат после проваленного smoke тоже код 1.
  Сценарий без кластера — `scripts/test-deploy-rollback.sh` (`make lint`). На живом кластере откат по-прежнему в `docs/cd-demo-log.md` и `make k8s-rollback-demo` (это `--atomic`, не ветка smoke).
- `make k8s-canary` собирает и импортирует `sensor-gateway` и `sensor-web` с тегом `CANARY_TAG`
  (по умолчанию `<короткий sha>-canary`, команда не принимает тег, равный `TAG`). В k3d импорт — `k3d image import -c $(CLUSTER)` (по умолчанию `mts`, та же переменная, что у `make up`). Дальше вызывается `scripts/canary.sh`.
  `make k8s-canary-fail` по-прежнему передаёт `TAG`: это образ stable после `make up`, проверяется отказ входа.
- Чарт пишет тег образа API в `APP_VERSION`. `GET /ready` отдаёт его в JSON (`version`) и в заголовке `X-App-Version`.
  Поле `version` у `GET /api/v1/service` остаётся `0.1.0`.
- `scripts/canary.sh TAG` ставит релиз `sensor-canary` с аннотациями ingress-nginx `canary`, `canary-weight`,
  `canary-by-header: X-Canary`. На каждом шаге (по умолчанию 10, 50, 100) ждёт, пока у backend canary
  `trafficShapingPolicy.weight` в ingress-nginx станет равен шагу (до 90 с, `/dbg backends`). Дальше:
  1. smoke через `X-Canary: always` и `EXPECT_VERSION` равный тегу canary: и JSON, и заголовок `/ready` должны совпасть с ним;
  2. `WEIGHT_SAMPLE_N` запросов (по умолчанию 100) на `/ready` без заголовка. Доля ответов canary — целое `hits*100/N`.
     Допуск: 10 → 2–25, 50 → 30–70, 100 → 100. Другой вес `w` от 1 до 99 — от `max(1, w-20)` до `min(99, w+20)`, вес 0 — только 0;
  3. та же доля по приросту счётчика `nginx_ingress_controller_requests`: числитель `canary=~".+sensor-canary.+"`,
     знаменатель — все запросы `exported_namespace="sensor"`. Перед базовой точкой пауза `WEIGHT_SETTLE_S` (20 с),
     чтобы smoke с `X-Canary: always` уже попал в scrape (интервал ServiceMonitor ingress-nginx — 15 с).
     Прирост общего счётчика меньше 80% серии за `WEIGHT_METRIC_WAIT_S` (60 с) — откат. Процент метрик — ближайшее целое;
  4. PromQL: `min(up{namespace="sensor",service="sensor-canary-api"}) == 1`, если target появился за 120 с;
     `sum(rate(nginx_ingress_controller_requests{exported_namespace="sensor",canary=~".+sensor-canary.+"}[2m])) > 0`
     (это canary-апстрим ingress-nginx, пробы kubelet сюда не попадают);
     доля 5xx среди них `>= 0` и `< 0.05`.
     `NaN`, `+Inf`, `-Inf`, пустое и нечисловое значение на любом из этих трёх запросов — откат.
     На awk Ubuntu (mawk) `NaN` и `Inf` становятся 0, поэтому голое сравнение «меньше 0.05» приняло бы пустой знаменатель.
  Prometheus недоступен → тоже откат, а не пропуск. Port-forward на 9090 поднимает `scripts/prom-forward.sh` и ждёт `/-/ready`.
  Любой провал → вес 0, удаление canary, `ROLLBACK canary: <причина>`. Stable при отказе гейта не меняется.
  Успех: `deploy.sh` обновляет stable на тег canary и ждёт rollout (`kubectl rollout status` api и web),
  затем вес canary в 0, то же ожидание weight в ingress-nginx, и только потом `helm uninstall sensor-canary`.
- Stable smoke во время canary шлёт `X-Canary: never`, чтобы проверять именно stable.
- У api и web RollingUpdate `maxUnavailable: 0`, `maxSurge: 1` и `preStop: sleep 5`: старый под не снимают, пока новый не Ready, и SIGTERM уходит только после паузы, чтобы Endpoints и kube-proxy успели убрать под. Иначе nginx web отдаёт 502. `terminationGracePeriodSeconds: 40` покрывает паузу и штатное завершение; uvicorn по SIGTERM сам перестаёт принимать соединения и дожидается текущих, отдельный обработчик в приложении не добавлялся.
- Stable: api и web по 2 реплики, PDB `minAvailable: 1`, HPA по CPU (min 2, max 4, 70%). Canary — 1 реплика без PDB и HPA, чтобы шаги веса и `helm uninstall` не ждали лишние поды и `preStop`. Подробности — в «Отказоустойчивость».

### Видео

Требования: до 5 минут, показать работающий стенд, а не установку с нуля; склейка и монтаж допустимы; сгенерированные кадры
не использовать. Пошаговый сценарий с таймингом — `docs/demo-script.md`. Ролик снимает команда.

### Что не проверено и ограничения

- **Canary-гейт с отдельным тегом** (доля веса по ответам и по счётчику ingress-nginx, отказ на NaN/Inf, promote через вес 0) на кластере не запускался. Локально проверены только разбор чисел и границы (`CANARY_SELF_TEST=1 ./scripts/canary.sh`), линтеры и pytest `/ready`. `docs/cd-demo-log.md` описывает прежний скрипт.
- **Нативный k3s на Ubuntu** (`make up K3D=0`) проверен только в GitHub Actions (e2e, `ubuntu-24.04`). На box его нет: в песочнице нет systemd и vxlan.
  Для k3d-прогонов на box понадобились параметры
  `K3D_PRELOAD=1` (из подов нет egress), `INGRESS_SERVICE_TYPE=NodePort` (не работает hostPort) и host-gw вместо vxlan —
  на обычной Ubuntu они не нужны. В песочнице нет и ipset, поэтому контроллер NetworkPolicy k3s там не стартует
  и `make k8s-netpol-check` честно падает; на GitHub-раннере (обычный kernel) проверка проходит.
- **ВМ libvirt.** Job `iac` зелёный на GitHub (pull request #3, run 39006928822, коммит `82bbe4f`) и локально на схеме с `github_token`: Terraform 1.9.8, провайдер 0.8.3 из lock-файла, `fmt -check`, `init -backend=false`, `validate` (без демона libvirt), `cloud-init schema` для `user-data.example.yaml` и `network-config.yaml`. `user-data.yaml.tftpl` схема не принимает: директивы `templatefile` ломают YAML. Живой `terraform apply` на box 2026-10-17 доведён при `vm_memory_mib=2048`, `vm_vcpu=2`, `run_make_up=false` и `TF_VAR_github_token` (лог `docs/iac-apply-log.md`): загрузка, cloud-init `status: done`, netplan, клон, `vm_ip` совпал с DHCP, затем `terraform destroy`. Переменной `github_token` в коде больше нет: клон без токена или через `github_deploy_key_path`. Этот вариант `apply` не проходил. `terraform fmt -check` и `validate` новой схемы — успех (Terraform 1.9.8, в том числе образ `hashicorp/terraform:1.9.8`). `terraform plan` без apply не дошёл до плана: нет `/var/run/libvirt/libvirt-sock`. Не запускались значения по умолчанию (8 ГиБ / 4 vCPU, `run_make_up=true`) и `make up K3D=0` внутри этой ВМ; нативный `make up K3D=0` по-прежнему только e2e. До успешного прогона экземпляр box пересоздали (оператор связывает это с нехваткой памяти). Повторный apply после возврата k3d не делался.
- Доставка алертов: webhook в кластерный `alert-sink` (пишет тело в лог). Почта и мессенджеры не настраивались.
- Видео: не записано в репозитории, его снимает команда (требования выше).
- `rollout status` возвращается, когда новые поды Ready, а старые ещё ~5 с отвечают в `preStop` со старым секретом. Поэтому `secrets-rotate.sh` и `secrets-apply.sh` после него ждут, пока старые поды API исчезнут: только после этого старый пароль гарантированно даёт 401. Ожидание идёт по всем подам с меткой `component=api`.
- Две реплики, PDB `minAvailable: 1`, HPA и egress NetworkPolicy проверены рендером (`helm lint`, `helm template` stable и canary, `make lint` / kubeconform). Живой кластер после этих правок не поднимался: `make k8s-netpol-check`, срабатывание HPA и `make k8s-alert-demo` (он на время проверки снимает HPA `sensor-api`) не повторялись. Прежний e2e проверял только ingress NetworkPolicy.

## Мониторинг и наблюдаемость

- Сервис отдаёт `/health`, `/ready`, `/metrics`. При успешной проверке готовности `GET /ready` отдаёт JSON `status` и `version` (тег образа из `APP_VERSION`) и заголовок `X-App-Version`; если проверка не проходит — 503, `service_up` становится 0. Метрики пишет `prometheus_client` 0.26.0: гистограмма `http_request_duration_seconds` и счётчик `http_requests_total` с метками `method`, `path` (шаблон маршрута, для несовпавшего пути `unmatched`), `status`; `service_up` — 1, если ключ сессии подписывает и проверяет токен; `service_probe_latency_seconds` — измеренное время последнего `POST /api/v1/service/probe` (синтетическое показание, без искусственной паузы). Реестр по умолчанию также отдаёт `process_*`, в том числе `process_resident_memory_bytes`.
- Снаружи `/metrics` закрыт: nginx web отвечает 403. Ingress направляет запрос на Service web и сам путь не режет. ServiceMonitor (label `release: mon`) скрейпит Service API напрямую, stable и canary.
- Метрики ingress-nginx (`controller.metrics.enabled`, ServiceMonitor `deploy/monitoring/ingress-nginx-servicemonitor.yaml`, интервал 15 с): по ним считаются трафик, доля 5xx canary и доля запросов canary-Ingress (label `canary`) от всех запросов namespace `sensor`.
- Дашборд Grafana `sensor-gateway` (`deploy/monitoring/dashboard-configmap.yaml`): число живых таргетов API, `up` по таргетам, req/s по сервисам, p95 `http_request_duration_seconds` (порог 0.5 с), доля 5xx через ingress-nginx.

  ![Grafana](docs/img/grafana-sensor-gateway.png)

  Скриншот снят 2026-10-17 на k3d-стенде из свежего клона (`scripts/grafana-screenshot.py`, headless Chrome). На снимке панель задержки — прежний gauge probe без порога. Сейчас на этом месте p95 гистограммы и порог 0.5 с. Повторный снимок не делался: кластер для этой правки не поднимался.

- Алерты (`deploy/monitoring/prometheusrule.yaml`):
  - `SensorGatewayDown` (critical): 1 минуту нет ни одного живого таргета API: `(sum(up{namespace="sensor",service=~".*-api"}) or vector(0)) == 0`;
  - `SensorGatewayNoReplicas` (critical): у Deployment в `sensor` `spec.replicas > 0`, а доступных реплик 0 (kube-state-metrics);
  - `SensorGatewayPodRestarts` (warning): больше 3 рестартов контейнера за 15 минут;
  - `SensorGatewayIngress5xx` (warning): доля 5xx через ingress-nginx в namespace `sensor` больше 5% 5 минут;
  - `SensorGatewayHighLatency` (warning): 2 минуты p95 `http_request_duration_seconds` больше 0.5 с: `histogram_quantile(0.95, sum by (le, service) (rate(http_request_duration_seconds_bucket{namespace="sensor"}[5m]))) > 0.5`. Пока запросов нет, `rate` пустой и алерт не зажигается.
  Все `SensorGateway.*` уходят на webhook `sensor-webhook`. Почему простой считается по `up`, а не по `service_up`: при падении пода ряд приложения исчезает; `up` выставляет Prometheus, а `or vector(0)` ловит и исчезновение ряда. `service_up` — проверка готовности внутри процесса.
- Доставка: Alertmanager шлёт `SensorGateway.*` (с `send_resolved`) на webhook `alert-sink` (`deploy/monitoring/alert-sink.yaml`).
  `make k8s-alert-demo` проверяет цепочку на `SensorGatewayDown`: снимает HPA `sensor-api`, `scale --replicas=0` → firing в Prometheus → active в Alertmanager →
  тело алерта в логе alert-sink → API обратно → алерт пропал и пришло `status: resolved`. Сценарий демо не менялся: задержку отдельно не поджигали, доставка у `SensorGatewayHighLatency` та же, потому что имя попадает в `SensorGateway.*`. Прогон Down — в e2e; лог —
  `docs/monitoring-alert-proof.md`, скриншоты `docs/img/prometheus-alert-firing.png`, `docs/img/alertmanager-alert.png`.
- Скриншот дашборда снимается `scripts/grafana-screenshot.py` (Playwright + headless Chrome).

## Отказоустойчивость

- Stable (`track=stable`): api и web по 2 реплики (`values.yaml`). PDB `policy/v1`, `minAvailable: 1` на оба Deployment: один под можно выселить, второй обслуживает. С одной репликой такой PDB блокировал бы drain — поэтому раньше стоял `maxUnavailable: 1`, который при одной реплике не оставлял запас.
- HPA `autoscaling/v2` по CPU, `hpa.enabled` по умолчанию true: min 2, max 4, target 70%. Отдельный объект на api и на web. CPU requests уже заданы (50m и 25m); без них utilization не считается. `helm upgrade --wait` ждёт Deployment, не HPA: если metrics-server недоступен, релиз всё равно Ready на числе реплик из чарта. В k3s metrics-server включён по умолчанию. Следующий `helm upgrade` записывает `spec.replicas` обратно в значение чарта (2); при нагрузке HPA поднимает его снова, до 4.
- Canary (`track=canary`): шаблон ставит 1 реплику и не рендерит PDB и HPA, даже если в values они включены. Иначе шаги 10→50→100 и `helm uninstall --wait` ждали бы вторую реплику и `preStop` (5 с).
- `scripts/canary.sh` ждёт `rollout status` Deployment, smoke идёт через ingress. `scripts/rollback-demo.sh` вызывает `deploy.sh` и смотрит `helm history`. `make k8s-rotate-demo` (`scripts/secrets-rotate-check.sh`) бьёт в ingress; `secrets-rotate.sh` перезапускает все Deployment API и ждёт, пока ни у одного пода не останется `deletionTimestamp`. Поиск по `replicas`, `pods -l`, `head -1`, `items[0]` в этих трёх скриптах на ровно одну реплику не указывает.
- `make k8s-alert-demo` ставит `sensor-api` в 0 реплик. HPA с min 2 вернул бы поды за один цикл, поэтому скрипт на это время удаляет HPA `sensor-api` и на выходе применяет его снова, а реплики возвращает к числу до проверки (если оно было 0 — к 2). Этот путь после появления HPA на кластере не прогонялся.

## Безопасность

- Compose: `DEMO_PASSWORD` из `.env` (не в git), пример — `.env.example`.
- Kubernetes: Secret `sensor-secrets` (`DEMO_PASSWORD`, `SESSION_SECRET`) зашифрован SOPS на ключ age. Приватный ключ —
  `~/.config/sops/age/keys.txt`, конфиг SOPS с публичным ключом — нетрекаемый `deploy/secrets/sops.local.yaml`.
  Трекаемые файлы скрипты не меняют. Ротация пароля, ключа сессий и ключа age — `deploy/secrets/README.md`.
- Сессия: подписанная cookie с истечением (12 ч), сравнение подписи за постоянное время; ротация пароля отзывает все сессии.
  Logout стирает cookie в браузере; сама подпись действительна до истечения или ротации — это осознанный компромисс stateless-сессий.
- Вход: не больше 30 попыток в минуту на IP клиента (429). Счётчик в памяти процесса API. Заголовки учитываются, только если TCP-пир входит в
  `TRUSTED_PROXY_CIDRS` (по умолчанию `10.42.0.0/16,10.43.0.0/16`, pod и service CIDR k3s; в чарте `env.trustedProxyCidrs`).
  Тогда ключ — `X-Real-IP`, а если его нет — самый правый адрес `X-Forwarded-For` вне этих сетей. От недоверенного пира берётся сам пир: подделанный `X-Forwarded-For` или `X-Real-IP` ключ не меняет.
  nginx web передаёт API `X-Real-IP`, который выставил ingress-nginx, и не пересылает клиентский `X-Forwarded-For`. В Compose пир — контейнер web, он не в этих сетях,
  поэтому лимит там общий на контейнер, а не на браузер.
- Снаружи `/metrics` закрывает nginx web (403). Ingress только направляет трафик на Service web. Скрейп — ServiceMonitor на Service API, его пускает NetworkPolicy из namespace monitoring.
- CI: Trivy блокирует образ с исправимыми HIGH/CRITICAL. На уровне workflow `permissions: contents: read`. `packages: write` только у job `images-publish` (push в GHCR и SBOM, только push в `main`). На pull request этот job не запускается: job `images` собирает и сканирует без push. Concurrency `ci-${{ github.ref }}`: push в одну ветку — очередь без отмены, чтобы параллельные прогоны не перетирали `:latest`; pull request — `cancel-in-progress`. Все `uses:` — полный SHA коммита и комментарий тега.
- e2e: `permissions: contents: read`, секретов workflow нет. `make up` вызывает `make status`; при `CI=true` пароли demo и Grafana в лог не попадают. Шаги «Mask stand passwords» после `make up` и после ротации читают ключи Secret и печатают `::add-mask::` (раннер прячет дальнейшие вхождения). Локально значение пароля печатает только `SHOW_SECRETS=1 make status`.
- CI, job `iac`: тот же Trivy v0.70.0 (`scan-type: config`, HIGH/CRITICAL) по чарту (рендер Kubernetes 1.31 и ServiceMonitor),
  обоим Dockerfile и `infra/terraform`. Чарт и Terraform без находок этого уровня. `apps/web/Dockerfile` — DS-0002 (нет `USER`):
  исключение в `apps/web/.trivyignore`, мастер nginx должен занять порт 80. Образный скан CVE это исключение не затрагивает.
- Grafana: пароль администратора случайный, лежит в SOPS-файле `deploy/secrets/grafana-admin.enc.yaml` (не в git), в кластер
  попадает Secret `grafana-admin` (`admin.existingSecret`). Смена пароля — `scripts/grafana-rotate.sh` (проверено на box: старый пароль → 401, новый → 200).
- Поды приложения: seccomp `RuntimeDefault`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem` (запись только в emptyDir), без токена ServiceAccount.
  API: `runAsNonRoot`, uid 65534, `drop: [ALL]`. Web (nginx): мастер-процесс стартует от root и
  сбрасывает права на воркеры, поэтому `drop: [ALL]` плюс только `CHOWN, SETUID, SETGID, NET_BIND_SERVICE, DAC_OVERRIDE`.
  У web pod-level `securityContext` — только seccomp, без `runAsNonRoot`: иначе мастер не займёт :80.
  Requests/limits — выше.
- NetworkPolicy, ingress как раньше: к API (порт 8000) пускают только web своего релиза и поды Prometheus (`app.kubernetes.io/name: prometheus` в namespace monitoring), к web (порт 80) — только
  namespace ingress-nginx. Egress у web: DNS (namespace `kube-system`, UDP и TCP 53) и TCP 8000 на api своего релиза. Egress у api пустой (`egress: []`): в `services/api/app/main.py` нет исходящих вызовов, DNS и Kubernetes API (токен ServiceAccount не монтируется). Ответ на уже принятое соединение политика не режет. Проверка ingress — `make k8s-netpol-check` в e2e (прогон до egress): из чужого namespace API и web недоступны, web через ingress-nginx отвечает 200, web своего релиза достаёт API. Egress на кластере не проверялся.
- kubeconfig нативного k3s: `/etc/rancher/k3s/k3s.yaml` с правами 600, копия пользователю в `~/.kube/config` (600).
- Supply chain: Trivy до push; SBOM (SPDX JSON, `anchore/sbom-action`, SHA в таблице инструментов) обоих образов — артефакт job `images-publish` на `main`. Подпись cosign keyless
  сознательно не используется: запись в публичный Rekor раскрыла бы имя приватного репозитория.
- Cloud-init не получает GitHub-токен. По умолчанию ВМ клонирует репозиторий по HTTPS без учётных данных.
  Для приватного репозитория — `github_deploy_key_path` (абсолютный путь к приватному ключу на хосте Terraform) и SSH `repo_url`.
  `runcmd` удаляет файл ключа с ВМ после clone (`/root/.config/mts/github-deploy-key.b64` и `/home/ubuntu/.ssh/github-deploy-key`).
  Если ключ передавали, его байты всё равно попадают в ISO cloud-init, в копию user-data на диске гостя (`/var/lib/cloud/instance/`) и в state Terraform (`*.tfstate` в `.gitignore`). Живой apply 2026-10-17 ещё использовал `github_token`; новая схема на ВМ не проверялась.

## Использование LLM

### Что это

В работе службы sensor-gateway языковой модели нет. LLM — опциональный локальный помощник: [Ternary-Bonsai-2-4B](https://huggingface.co/prism-ml/Ternary-Bonsai-2-4B-gguf) Q2_0 (файл `Ternary-Bonsai-2-4B-Q2_0.gguf`, 1.21 ГБ, Apache-2.0, без токена; sha256 в `llm/models.tsv`, проверяет `make llm-fetch`) на llama.cpp, образ `ghcr.io/ggml-org/llama.cpp:server-b11681`. Только CPU (AVX2), без GPU. Лимит контейнера 2 ГБ (`LLM_MEM`, по умолчанию `2g` в `scripts/llm-up.sh`). Внешних API и ключей нет. `make up`, `make k8s-up` и CI модель не запускают: job `llm` гоняет валидатор (`make llm-test`), не llama-server.

Пиковый RSS 1.66 ГБ (0.47 ГБ анонимной + 1.19 ГБ отображённых весов) и 14.5 ток/с — прежний замер на 6 потоках (`LLM_THREADS=6`), в повтор 2026-10-17 не снимались. По умолчанию сервер берёт `-t 4`. Запасной файл для машин с 8 ГБ — `LLM_NAME=ternary-bonsai-2-2b`; в этот день не запускался. Сравнение семи моделей — [docs/llm/model-choice.md](docs/llm/model-choice.md).

### За что отвечает

- Черновик правила алерта по одной фразе (`make llm-gen` → PrometheusRule).
- Объяснение отката canary (`make llm-explain`). Если llama-server отвечает на `/health`, `scripts/canary.sh` после отката сам вызывает `scripts/llm-explain-hook.sh`: текст в консоль и в `llm/out/canary-explain-<время>.md`. Откат к этому моменту уже сделан. Хук всегда завершается с 0, таймаут `LLM_EXPLAIN_TIMEOUT` (240 с). Сервера нет — одна строка «объяснение пропущено». Выключить: `LLM_EXPLAIN=0`.
- Черновик release notes (`make llm-notes`) из `git log` и diffstat. В коде это `llm/llm_gen.py notes` и промпт `llm/prompts/release-notes.system.txt`: разделы «Что изменилось», «Риски», «Как проверить», только по файлам из входа. В `docs/llm/examples/runs.jsonl` один такой прогон: `2026-10-17T04:40:03+0300`, 59.29 с, valid.

### Как работать

```bash
make llm-up
make llm-gen DESC="Critical alert when service_probe_latency_seconds is above 1 second for 2 minutes"
make llm-explain
make llm-notes RANGE=HEAD~3..HEAD
make llm-test
make llm-down
```

`service_probe_latency_seconds` — ряд, который API пишет на `/metrics` (`services/api/app/main.py`). Та же фраза — `DESC` по умолчанию в Makefile. Доля 5xx на стенде считается по `nginx_ingress_controller_requests` (метки `exported_namespace`, `status` в `deploy/monitoring/prometheusrule.yaml`): это трафик через ingress, а не scrape API. У `http_requests_total` есть метки `method`, `path` и `status`. Гистограмма `http_request_duration_seconds` отдаёт `http_request_duration_seconds_bucket` (ещё метка `le`), `_sum` и `_count` с теми же метками приложения. Эти ряды и метки перечислены в `llm/metrics_whitelist.yaml`. `process_resident_memory_bytes` process collector отдаёт, в белый список он не входит.

`make llm-up` качает веса в `llm/models/` и поднимает llama-server на `127.0.0.1:8090`. `make llm-explain` без `LOG` читает `llm/examples/canary-fail.log`. `make llm-test` — pytest валидатора без модели.

### Что проверяется автоматически

В `llm-gen` (`llm/llm_gen.py`): YAML; структура правила (`apiVersion`/`kind`, DNS-1123 имя, `release: mon`, CamelCase, duration если указан `for`, `severity` warning|critical, summary и description); `promtool check rules` (образ `prom/prometheus:v2.54.1`); белый список `llm/metrics_whitelist.yaml`. Неизвестная метрика или метка — невалидно. `histogram_quantile` только по ряду с суффиксом `_bucket` из этого списка: для задержки HTTP это `http_request_duration_seconds_bucket`. По самому `http_requests_total` квантиль невалиден. Отдельно: `rate()`/`irate()`/`increase()` по gauge и regex в `=`-матчере. При ошибке один раунд: текст ошибок уходит модели, ответ проверяется снова. Не прошёл — код выхода 1.

В `llm-explain`: ответ на русском (доля кириллицы ≥ 0.5, иначе один повтор) и числа из 3+ цифр. Число должно быть отдельным токеном лога: `202` внутри даты `2026-10-16` не считается найденным. Числа из 1–2 цифр (веса 10 и 50) не сверяются. В `docs/llm/examples/canary-fail-explain.md` cookie названа `dts_session`: так она называлась в прогоне 2026-10-17. Сейчас имя — `sensor_session`.

Каждый запуск пишет `llm/out/runs.jsonl`. Поле `model` — id загруженной модели (`GET /v1/models`), если сервер его не отдал — поле `model` ответа, иначе `LLM_MODEL`, иначе первая строка `llm/models.tsv`. Рядом seed 42, temperature 0, файл промпта, полный запрос (поле `user`), время, токены, результат. Промпты — `llm/prompts/*.txt`. Копия прогонов 2026-10-17 — `docs/llm/examples/runs.jsonl`.

### Ограничения

Черновик правила — для ревью человеком, не для автодеплоя: promtool и белый список не проверяют смысл выражения. Объяснение — подсказка, откат от него не зависит. В `docs/llm/examples/canary-rollback-hook.log` откат уже записан в `2026-10-17T01:57:29Z`, объяснение печатается следом, строка `canary.sh rolled back` — `2026-10-17T01:58:01Z`. Модель назвала HTTP 000 и написала, что smoke stable прошёл, хотя этой строки в логе не было. Повтор `make llm-explain` 2026-10-17 (66.67 с, attempts 1, valid) — `docs/llm/examples/canary-fail-explain.md`, там снова «stable прошёл».

Ответ в `docs/llm/examples/runs.jsonl` занимает от 15.71 с до 104.27 с. Повтор трёх фраз 2026-10-17 (`-t 4`), белого списка тогда не было: 5xx 16.88 с, attempts 1, valid (выражение с `status` у `http_requests_total`; эта метка сейчас в списке, `histogram_quantile` по самому счётчику, не по `*_bucket`, по-прежнему невалиден); задержка 51.11 с, attempts 2, valid false (promtool: range vector в `sum`); память 104.27 с, attempts 2, valid по тем проверкам (`process_resident_memory_bytes` process collector отдаёт, в белом списке его нет). Explain 66.67 с, attempts 1, valid. Прогоны сделаны, когда API ещё не подключал `prometheus_client`.

`docs/llm/examples/prometheusrule-memory.generated.yaml` — ранний английский прогон, не повтор 2026-10-17. В журнале две строки задачи `Critical when process_resident_memory_bytes is above 400MB for 10m`: `2026-10-17T04:37:27+0300`, 15.71 с, attempts 1, valid, completion_tokens 145; `2026-10-17T04:38:04+0300`, 25.91 с, attempts 1, valid, completion_tokens 145. Текста правила в журнале нет, файл к одной из строк не привязан. Русский повтор той же темы (`2026-10-17T07:27:17+0000`, 104.27 с, attempts 2, completion_tokens 152) YAML в репозитории не оставил.

После `make llm-up` сеть нужна только чтобы скачать веса и образы. Дальше запросы идут на `127.0.0.1:8090`, ключ не нужен.

## Troubleshooting

- `make status` не показывает пароль — так и задумано. В выводе команда `kubectl … | base64 -d`. Напечатать значение: `SHOW_SECRETS=1 make status`. В GitHub Actions (`CI=true`) значение в лог не попадает, даже если задать `SHOW_SECRETS=1`.
- `make: command not found` — выполнить строку подготовки Ubuntu из «Как запустить».
- `make lint` не тянет образ или схему kubeconform — нужен Docker в PATH и исходящий HTTPS. Helm v3.16.3 и kubeconform 0.6.7 при отсутствии нужной версии ставятся в `~/.local/bin` без sudo.
- Порт 8081 (k3d) или 8080 (`make demo`) занят — остановить другой процесс.
- API не проходит healthcheck — в `.env` пароль короче 12 символов: `docker compose logs api`.
- После входа снова форма — открывать именно `http://127.0.0.1:8080`, не файл и не другой хост.
- Образ не собирается — нужен BuildKit и Compose V2 (есть в Ubuntu 24.04).
- `make up K3D=0` падает на установке k3s — нужен sudo и доступ к get.k3s.io (режим k3d по умолчанию get.k3s.io не использует); повторный запуск идемпотентен.
- `sha256 не совпал` при установке helm, kubectl или k3d — скачанный файл не равен сумме в `scripts/k3s-install.sh`. Повторный запуск качает файл заново. Если бинарь этой версии уже есть, скрипт его не перекачивает и сумму не считает.
- Повторный `make up` пишет `предупреждение: k3d-кластер … уже существует` — образ, порт и `K3D_EXTRA_ARGS` к живому кластеру не применяются. Другое имя: `make up CLUSTER=имя`. Сменить параметры того же имени: `k3d cluster delete имя` и снова `make up`. `make k8s-canary` импортирует образы в тот же `CLUSTER`.
- Поды в `ImagePullBackOff` — образы приложения не импортированы: stable — `make k8s-images` (тег `TAG`), canary — `make k8s-canary` (тег `CANARY_TAG`). Импорт k3d идёт в кластер `CLUSTER`. При закрытом egress из подов `K3D_PRELOAD=1` подгружает в k3d сторонние образы (ingress-nginx, мониторинг, alert-sink); образы приложения этот флаг не подменяет.
- `sensor.localtest.me` не открывается — DNS не отдаёт 127.0.0.1: добавить `127.0.0.1 sensor.localtest.me grafana.localtest.me` в `/etc/hosts`.
- Smoke падает на входе после смены секрета — Secret читается подами при старте; `scripts/secrets-apply.sh` сам делает `rollout restart`.
- `Ключ age этой машины не совпадает с получателем` — файл зашифрован другим ключом: удалить `deploy/secrets/sensor-secrets.enc.yaml`
  и запустить `scripts/secrets-init.sh` заново (будет новый пароль).
- Canary откатился с `not a finite number` — Prometheus вернул NaN, Inf или нечисло. У доли 5xx так бывает, когда в знаменателе нет трафика: это откат, а не «ниже 0.05».
- Canary откатился с `response share` или `ingress canary share` — доля canary не попала в допуск веса. Если `CANARY_TAG` совпадает с версией, которую уже отдаёт stable, шаг 10 даёт около 100% и тоже откатывается.
- `CANARY_TAG совпадает с TAG` — `make k8s-canary` требует другой тег. По умолчанию берётся `<sha>-canary`.
- Canary откатился с `prometheus returned no sample` или счётчик ingress «rose by» меньше 80% серии — Prometheus ещё не снял точки: увеличить `ANALYSIS_WAIT_S` (75 с) или `WEIGHT_METRIC_WAIT_S` (60 с). Пауза перед выборкой веса — `WEIGHT_SETTLE_S` (20 с).
- Canary откатился с `prometheus unreachable` — нет доступа к Prometheus на 9090: смотреть `/tmp/prom-forward.log`
  (port-forward поднимает `scripts/prom-forward.sh`) или задать `PROM_URL`.
- `make k8s-netpol-check` падает с `REACHED` из чужого namespace — в кластере не работает контроллер NetworkPolicy
  (например, нет модуля ipset в ядре).
- Снаружи `/metrics` отвечает 403 — это nginx web. `controller.allowSnippetAnnotations` не включается: у ingress-nginx 4.11.3 сниппеты выключены по умолчанию (CVE-2021-25742). Ingress ведёт только на Service web.
- Все клиенты получают 429 вместе — адрес web-пода не входит в `TRUSTED_PROXY_CIDRS` (другой cluster-cidr). Задать сети в `env.trustedProxyCidrs` и перекатить релиз.
- HPA в статусе `FailedGetResourceMetric` — нет API `metrics.k8s.io`. Deployment при этом остаётся на своём `spec.replicas` (у stable это 2): `helm --wait` условие HPA не ждёт. На k3s metrics-server стоит по умолчанию (`kubectl get apiservice v1beta1.metrics.k8s.io`).
- `make k8s-alert-demo` не дожидается firing — HPA `sensor-api` не снялся и вернул реплики. Скрипт удаляет его сам; ручной `scale --replicas=0` без `kubectl -n sensor delete hpa sensor-api` нуль не удержит.

## Лицензия

MIT. Текст в файле `LICENSE`.

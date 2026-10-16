# Сценарий видео-демо (до 5 минут)

Требования: до 5 минут, показывать работающий стенд, а не установку с нуля. Склейка и монтаж допустимы.
Сгенерированные кадры не использовать. Перед записью стенд уже поднят (`make up` и `make k8s-up`).

| Время | Что на экране | Команда / действие |
| --- | --- | --- |
| 0:00–0:20 | README: проблема и схема | открыть README на GitHub |
| 0:20–0:50 | push → GitHub Actions: lint, api, web, manifests, dockerfiles, shellcheck, helm, images (Trivy, push в GHCR) | вкладка Actions, последний зелёный прогон |
| 0:50–1:20 | Compose-демо: вход и probe | `make up`, открыть http://127.0.0.1:8080, войти, «Проверить службу» |
| 1:20–1:50 | Кластер: поды, ingress, релизы | `kubectl get pods -A`, `helm list -A`, открыть http://sensor.localtest.me |
| 1:50–2:40 | Canary с анализом и promote | `make k8s-canary` (склеить ожидание анализа) |
| 2:40–3:20 | Провал canary → автоматический откат, stable не задет | `./scripts/canary-fail-demo.sh <tag>` |
| 3:20–3:40 | Откат битого релиза `--atomic` | `make k8s-rollback-demo`, `helm history sensor -n sensor` |
| 3:40–4:10 | Ротация секрета: старый пароль 401, новый 200 | `./scripts/secrets-rotate-check.sh` |
| 4:10–4:50 | Grafana-дашборд, падение службы, алерт firing | `kubectl -n sensor scale deploy sensor-api --replicas=0`, Prometheus `/alerts`, Alertmanager (склейка ~2 мин ожидания) |
| 4:50–5:00 | Восстановление | `kubectl -n sensor scale deploy sensor-api --replicas=1` |

Подсказки: Grafana — http://grafana.localtest.me (admin/admin в демо), Prometheus — `kubectl -n monitoring port-forward svc/mon-kube-prometheus-stack-prometheus 9090:9090`.

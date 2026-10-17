# Сценарий видео-демо (до 5 минут)

Требования: до 5 минут, показывать работающий стенд, а не установку с нуля. Склейка и монтаж допустимы.
Сгенерированные кадры не использовать. Перед записью стенд уже поднят командой `make up`. Ролик снимает команда.

| Время | Что на экране | Команда / действие |
| --- | --- | --- |
| 0:00–0:20 | README: проблема и схема | открыть README на GitHub |
| 0:20–0:50 | GitHub Actions: `ci` (линт, тесты, kubeconform, hadolint, shellcheck, Trivy, SBOM, push в GHCR) и `e2e` (k3d и k3s) | вкладка Actions, последний зелёный прогон |
| 0:50–1:10 | Стенд: адреса и пароли, поды и релизы | `make status`, `kubectl get pods -A`, `helm list -A` |
| 1:10–1:30 | Вход и probe в браузере | http://sensor.localtest.me:8081, логин `demo`, «Проверить службу» |
| 1:30–2:20 | Canary 10→50→100: smoke и PromQL (up, трафик, 5xx по ingress-nginx), promote | `make k8s-canary` (ожидание анализа склеить) |
| 2:20–2:50 | Провал canary → автооткат, stable не задет | `make k8s-canary-fail` |
| 2:50–3:10 | Битый тег → откат `--atomic` | `make k8s-rollback-demo` |
| 3:10–3:40 | Ротация секрета: старый пароль и cookie 401, новый 200 | `make k8s-rotate-demo` |
| 3:40–4:40 | Grafana-дашборд; алерт firing → webhook → resolved | `make k8s-alert-demo` (ожидание склеить), Grafana http://grafana.localtest.me:8081 |
| 4:40–5:00 | NetworkPolicy | `make k8s-netpol-check` (на обычной Ubuntu; в песочнице без ipset не работает) |

Пароль Grafana печатает `make status`.

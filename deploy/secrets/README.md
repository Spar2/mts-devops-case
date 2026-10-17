# Секреты: SOPS 3.9.2 + age 1.2.1

Secret `sensor-secrets` (ns `sensor`) содержит `DEMO_PASSWORD` и `SESSION_SECRET` (ключ подписи сессий).
В кластер он попадает только из файла, зашифрованного SOPS на публичный ключ age.

## Что где лежит

| Файл | В git | Что это |
| --- | --- | --- |
| `~/.config/sops/age/keys.txt` | нет | приватный ключ age этой машины (права 600) |
| `deploy/secrets/sops.local.yaml` | нет | конфиг SOPS с публичным ключом стенда, генерирует `secrets-init.sh` |
| `deploy/secrets/sensor-secrets.enc.yaml` | нет | Secret, зашифрованы только `data`/`stringData`; `make up` создаёт файл локально |
| `scripts/secrets-*.sh` | да | init / apply / rotate / rotate-check |

Почему зашифрованный файл не в git: `*.enc.yaml` в `.gitignore`, у каждого стенда свой ключ age.
`make up` создаёт `deploy/secrets/sensor-secrets.enc.yaml` и `grafana-admin.enc.yaml` локально.
Приватный ключ `keys.txt` остаётся вне git.

## Команды

- `scripts/secrets-init.sh` — ставит sops и age в `~/.local/bin`, создаёт ключ age (если нет),
  пишет `sops.local.yaml`, создаёт и шифрует Secret. Пароль: `DEMO_PASSWORD` из окружения или случайные 24 символа.
  Повторный запуск существующий файл не трогает.
- `scripts/secrets-apply.sh` — `sops -d | kubectl apply`; если Secret изменился, делает `rollout restart` API.
- `scripts/secrets-rotate.sh` — новый пароль → `sops set` → apply → `rollout restart` → ожидание.
- `scripts/secrets-rotate-check.sh` — e2e-проверка ротации (лог: `docs/secrets-rotation-log.md`).

## Ротация DEMO_PASSWORD

1. `scripts/secrets-rotate.sh`.
2. Ключ подписи сессий выводится из `SESSION_SECRET` и `DEMO_PASSWORD`, поэтому все старые cookie
   становятся недействительны сразу после перезапуска подов, старый пароль даёт 401.
3. Проверка: `INGRESS_PORT=<порт> scripts/secrets-rotate-check.sh`.

## Ротация SESSION_SECRET

`sops set deploy/secrets/sensor-secrets.enc.yaml '["stringData"]["SESSION_SECRET"]' "\"$(openssl rand -hex 24)\""`,
затем `scripts/secrets-apply.sh` (перезапустит API). Все сессии отзываются, пароль прежний.

## Ротация ключа age

1. `age-keygen -o new-keys.txt`; добавить новую пару в `~/.config/sops/age/keys.txt` (старую пока оставить).
2. В `deploy/secrets/sops.local.yaml` в поле `age` указать новый публичный ключ.
3. `sops --config deploy/secrets/sops.local.yaml updatekeys -y deploy/secrets/sensor-secrets.enc.yaml`.
4. Проверить `sops -d deploy/secrets/sensor-secrets.enc.yaml >/dev/null`, затем удалить старую пару из `keys.txt`.
5. Если ключ скомпрометирован, после смены ключа обязательно сменить и сами значения (`secrets-rotate.sh`):
   старые версии файла остались расшифровываемыми старым ключом.

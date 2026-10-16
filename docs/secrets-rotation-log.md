# Лог проверки ротации DEMO_PASSWORD (k3d, 2026-10-17 02:46 MSK)

Secret содержит `DEMO_PASSWORD` и `SESSION_SECRET` (создан `secrets-init.sh`), образ с подписанными сессиями.
`INGRESS_PORT=18081 scripts/secrets-rotate-check.sh`:

```text
PASS вход со старым паролем до ротации (200)
PASS старая cookie до ротации (200)
PASS пароль в Secret сменился
PASS вход со старым паролем после ротации (401)
PASS старая cookie после ротации (401)
PASS вход с новым паролем (200)
PASS новая cookie (200)
```

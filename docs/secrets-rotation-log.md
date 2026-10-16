# Лог проверки ротации DEMO_PASSWORD (k3d, 2026-10-17 01:54 MSK)

`INGRESS_PORT=18081 scripts/secrets-rotate-check.sh`, образ с подписанными сессиями:

```text
PASS вход со старым паролем до ротации (200)
PASS старая cookie до ротации (200)
PASS пароль в Secret сменился
PASS вход со старым паролем после ротации (401)
PASS старая cookie после ротации (401)
PASS вход с новым паролем (200)
PASS новая cookie (200)
```

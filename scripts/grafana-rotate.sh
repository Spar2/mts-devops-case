#!/usr/bin/env bash
# Новый случайный пароль администратора Grafana: sops set в
# deploy/secrets/grafana-admin.enc.yaml, apply Secret grafana-admin, рестарт Grafana.
# Пароль в лог не печатается (SHOW_SECRETS=1 make status).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"
key_file="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
enc_rel="deploy/secrets/grafana-admin.enc.yaml"
[[ -f "${root}/${enc_rel}" ]] || { echo "Нет ${enc_rel}. Сначала: scripts/secrets-init.sh" >&2; exit 1; }
if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "${key_file}" ]]; then
  export SOPS_AGE_KEY_FILE="${key_file}"
fi
cd "${root}"
sops set "${enc_rel}" '["stringData"]["admin-password"]' "\"$(openssl rand -hex 16)\""
sops -d "${enc_rel}" | kubectl apply -f -
# Grafana берёт пароль из Secret при старте и сама обновляет пароль admin.
kubectl -n monitoring rollout restart deployment/mon-grafana
kubectl -n monitoring rollout status deployment/mon-grafana --timeout=180s
echo "Пароль Grafana сменён (показать: SHOW_SECRETS=1 make status)."

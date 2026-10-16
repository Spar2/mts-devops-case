#!/usr/bin/env bash
# Generate a new DEMO_PASSWORD, store it with sops set, apply, restart API, wait.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"
key_file="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
enc_rel="deploy/secrets/sensor-secrets.enc.yaml"

die() {
  echo "$*" >&2
  exit 1
}

quote_scalar() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "${s}"
}

command -v sops >/dev/null 2>&1 || die "Нет sops в PATH. Сначала: scripts/secrets-init.sh"
command -v kubectl >/dev/null 2>&1 || die "Нет kubectl в PATH."
command -v openssl >/dev/null 2>&1 || die "Нужен openssl, чтобы сгенерировать пароль."
[[ -f "${root}/${enc_rel}" ]] || die "Нет ${enc_rel}. Сначала: scripts/secrets-init.sh"

if [[ -z "${SOPS_AGE_KEY:-}" && -z "${SOPS_AGE_KEY_FILE:-}" && ! -f "${key_file}" ]]; then
  die "Нет приватного ключа age: ${key_file}. В git его нет."
fi
if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "${key_file}" ]]; then
  export SOPS_AGE_KEY_FILE="${key_file}"
fi

password="$(openssl rand -base64 18 | tr -d '\n')"
[[ ${#password} -eq 24 ]] || die "openssl вернул не 24 символа (${#password})."

cd "${root}"
sops set "${enc_rel}" '["stringData"]["DEMO_PASSWORD"]' "$(quote_scalar "${password}")"
echo "Новый DEMO_PASSWORD записан в ${enc_rel}: ${password}"

kubectl create namespace sensor --dry-run=client -o yaml | kubectl apply -f -
sops -d deploy/secrets/sensor-secrets.enc.yaml | kubectl apply -f -
kubectl -n sensor rollout restart deploy -l app.kubernetes.io/component=api
kubectl -n sensor rollout status deploy -l app.kubernetes.io/component=api --timeout=180s

echo "Deployment с меткой app.kubernetes.io/component=api перезапущен."
echo "Закоммитьте ${enc_rel}. Приватный ключ age в git не класть."

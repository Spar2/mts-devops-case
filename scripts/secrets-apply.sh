#!/usr/bin/env bash
# Create namespace sensor if needed and apply the decrypted sensor-secrets Secret.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"
key_file="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
enc_rel="deploy/secrets/sensor-secrets.enc.yaml"

die() {
  echo "$*" >&2
  exit 1
}

command -v sops >/dev/null 2>&1 || die "Нет sops в PATH. Сначала: scripts/secrets-init.sh"
command -v kubectl >/dev/null 2>&1 || die "Нет kubectl в PATH."
[[ -f "${root}/${enc_rel}" ]] || die "Нет ${enc_rel}. Сначала: scripts/secrets-init.sh"

if [[ -z "${SOPS_AGE_KEY:-}" && -z "${SOPS_AGE_KEY_FILE:-}" && ! -f "${key_file}" ]]; then
  die "Нет приватного ключа age: ${key_file}. В git его нет. На этой машине его создаёт scripts/secrets-init.sh."
fi
if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "${key_file}" ]]; then
  export SOPS_AGE_KEY_FILE="${key_file}"
fi

cd "${root}"
if [[ -f deploy/secrets/grafana-admin.enc.yaml ]]; then
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  sops -d deploy/secrets/grafana-admin.enc.yaml | kubectl apply -f -
fi
kubectl create namespace sensor --dry-run=client -o yaml | kubectl apply -f -
out="$(sops -d deploy/secrets/sensor-secrets.enc.yaml | kubectl apply -f -)"
echo "${out}"
# Поды читают секрет из env только при старте: если Secret изменился, перезапускаем API.
if [[ "${out}" == *configured* ]] && kubectl -n sensor get deploy -l app.kubernetes.io/component=api -o name | grep -q .; then
  kubectl -n sensor rollout restart deploy -l app.kubernetes.io/component=api
  kubectl -n sensor rollout status deploy -l app.kubernetes.io/component=api --timeout=180s
  # rollout status возвращается, когда новые поды Ready; старые ещё ~5 с отвечают в preStop
  # со старым секретом. Ждём, пока они исчезнут: дальше секрет действует у всех подов API.
  for _ in $(seq 1 60); do
    kubectl -n sensor get pods -l app.kubernetes.io/component=api \
      -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"\n"}{end}' | grep -q . || break
    sleep 1
  done
fi

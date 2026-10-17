#!/usr/bin/env bash
# Install sops 3.9.2 and age 1.2.1 into ~/.local/bin, ensure an age key,
# write its recipient into deploy/secrets/sops.local.yaml (untracked), and encrypt sensor-secrets.
set -euo pipefail

sops_version=3.9.2
age_version=1.2.1

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${HOME}/.local/bin"
key_file="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
# Сгенерированный конфиг SOPS с публичным ключом этого стенда. Не трекается git,
# трекаемые файлы не меняются.
sops_config="${root}/deploy/secrets/sops.local.yaml"
enc_file="${root}/deploy/secrets/sensor-secrets.enc.yaml"

mkdir -p "${bin}"
export PATH="${bin}:${PATH}"

die() {
  echo "$*" >&2
  exit 1
}

has_version() {
  local cmd=$1 expected=$2
  [[ -x "${bin}/${cmd}" ]] || return 1
  "${bin}/${cmd}" --version 2>&1 | grep -q -F -- "${expected}"
}

sha256_check() {
  local file=$1 sum=$2
  echo "${sum}  ${file}" | sha256sum -c -
}

download() {
  local url=$1 dest=$2 sum=$3
  command -v curl >/dev/null 2>&1 || die "Нужен curl, чтобы скачать ${url}."
  command -v sha256sum >/dev/null 2>&1 || die "Нужен sha256sum."
  curl -fsSL --retry 3 --retry-delay 2 -o "${dest}" "${url}"
  sha256_check "${dest}" "${sum}"
}

install_sops() {
  if has_version sops "${sops_version}"; then
    return
  fi
  local asset sum tmp
  case "$(uname -m)" in
    x86_64)
      asset="sops-v${sops_version}.linux.amd64"
      sum="8d939bb53fe3f05b12ba4bec85c562e843b7fccba9a867cbfa626caa06a39eed"
      ;;
    aarch64 | arm64)
      asset="sops-v${sops_version}.linux.arm64"
      sum="07ff67d6ec28b2660c6bc2b065fa8f949dd51f15522e0770ebea781a0df00faf"
      ;;
    *)
      die "Архитектура $(uname -m) не поддерживается. Нужны linux/amd64 или linux/arm64."
      ;;
  esac
  tmp="$(mktemp)"
  download "https://github.com/getsops/sops/releases/download/v${sops_version}/${asset}" "${tmp}" "${sum}"
  install -m 0755 "${tmp}" "${bin}/sops"
  rm -f "${tmp}"
}

install_age() {
  if has_version age "v${age_version}" && has_version age-keygen "v${age_version}"; then
    return
  fi
  local asset sum tmp
  case "$(uname -m)" in
    x86_64)
      asset="age-v${age_version}-linux-amd64.tar.gz"
      sum="7df45a6cc87d4da11cc03a539a7470c15b1041ab2b396af088fe9990f7c79d50"
      ;;
    aarch64 | arm64)
      asset="age-v${age_version}-linux-arm64.tar.gz"
      sum="57fd79a7ece5fe501f351b9dd51a82fbee1ea8db65a8839db17f5c080245e99f"
      ;;
    *)
      die "Архитектура $(uname -m) не поддерживается. Нужны linux/amd64 или linux/arm64."
      ;;
  esac
  command -v tar >/dev/null 2>&1 || die "Нужен tar, чтобы распаковать age."
  tmp="$(mktemp -d)"
  download "https://github.com/FiloSottile/age/releases/download/v${age_version}/${asset}" "${tmp}/age.tar.gz" "${sum}"
  tar -xzf "${tmp}/age.tar.gz" -C "${tmp}"
  install -m 0755 "${tmp}/age/age" "${bin}/age"
  install -m 0755 "${tmp}/age/age-keygen" "${bin}/age-keygen"
  rm -rf "${tmp}"
}

quote_scalar() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "${s}"
}

write_recipient() {
  local recipient=$1
  cat >"${sops_config}" <<YAML
# Сгенерировано scripts/secrets-init.sh для этого стенда. В git не попадает.
creation_rules:
  # Путь сверяется относительно каталога этого конфига (deploy/secrets).
  - path_regex: \\.enc\\.yaml\$
    encrypted_regex: '^(data|stringData)\$'
    age: ${recipient}
YAML
  chmod 644 "${sops_config}"
}

install_sops
install_age

if [[ ! -e "${key_file}" ]]; then
  mkdir -p "$(dirname "${key_file}")"
  chmod 700 "$(dirname "${key_file}")"
  (umask 077; age-keygen -o "${key_file}")
fi
[[ -f "${key_file}" ]] || die "Ключ age не обычный файл: ${key_file}."
chmod 600 "${key_file}"

recipient="$(age-keygen -y "${key_file}" | tr -d '\r' | paste -sd, -)"
[[ "${recipient}" =~ ^age1[0-9a-z]+(,age1[0-9a-z]+)*$ ]] || die "Некорректный публичный ключ age: ${recipient}"
write_recipient "${recipient}"

if [[ -f "${enc_file}" ]]; then
  echo "Файл уже есть, не перезаписываю: ${enc_file}"
  mismatch=0
  IFS=',' read -ra pubs <<< "${recipient}"
  for pub in "${pubs[@]}"; do
    if ! grep -q -F "recipient: ${pub}" "${enc_file}"; then
      mismatch=1
    fi
  done
  if [[ "${mismatch}" -eq 1 ]]; then
    echo "Ключ age этой машины не совпадает с получателем ${enc_file}." >&2
    echo "Если это стенд проверки: rm ${enc_file} и запустить снова (будет новый пароль). Смена ключа — deploy/secrets/README.md." >&2
    exit 1
  fi
  exit 0
fi

if [[ -n "${DEMO_PASSWORD:-}" ]]; then
  password="${DEMO_PASSWORD}"
  password_source="из переменной DEMO_PASSWORD"
else
  command -v openssl >/dev/null 2>&1 || die "Нужен openssl, чтобы сгенерировать DEMO_PASSWORD."
  password="$(openssl rand -base64 18 | tr -d '\n')"
  password_source="случайный, 24 символа"
  [[ ${#password} -eq 24 ]] || die "openssl вернул не 24 символа (${#password})."
fi
[[ ${#password} -ge 12 ]] || die "DEMO_PASSWORD короче 12 символов. API с таким паролем не стартует."
if [[ "${password}" =~ [^[:print:]] ]]; then
  die "DEMO_PASSWORD содержит непечатные символы."
fi

mkdir -p "$(dirname "${enc_file}")"
plain="$(mktemp "${root}/deploy/secrets/tmp.XXXXXX.enc.yaml")"
chmod 600 "${plain}"
cleanup() {
  rm -f "${plain}"
}
trap cleanup EXIT

{
  printf '%s\n' \
    'apiVersion: v1' \
    'kind: Secret' \
    'metadata:' \
    '  name: sensor-secrets' \
    '  namespace: sensor' \
    'type: Opaque' \
    'stringData:'
  printf '  DEMO_PASSWORD: %s\n' "$(quote_scalar "${password}")"
  # Ключ подписи сессий (общий для stable и canary; ротация DEMO_PASSWORD тоже отзывает сессии).
  printf '  SESSION_SECRET: %s\n' "$(quote_scalar "$(openssl rand -hex 24)")"
} > "${plain}"

export SOPS_AGE_KEY_FILE="${key_file}"
cd "${root}"
sops --config "${sops_config}" --encrypt --in-place "${plain}"
trap - EXIT
mv "${plain}" "${enc_file}"
chmod 644 "${enc_file}"

echo "Зашифрован ${enc_file} (пароль ${password_source})."
echo "Пароль входа в лог не пишется: его показывает make status (читает Secret sensor-secrets)."
echo "Приватный ключ age: ${key_file}"
echo "Этот ключ в git не класть."

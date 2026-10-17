#!/usr/bin/env bash
# Проверка манифестов kubeconform 0.6.7 — та же, что job manifests в .github/workflows/ci.yml.
# Рендер чарта stable и canary (api-versions ServiceMonitor) и два файла deploy/monitoring.
# Helm v3.16.3 и kubeconform берутся из PATH; если версии нет — бинарь качается в ~/.local/bin
# и сверяется sha256 (без sudo). Флаг --ensure-tools только ставит бинари и выходит.
set -euo pipefail

cd "$(dirname "$0")/.."

HELM_VERSION=v3.16.3
KUBECONFORM_VERSION=0.6.7

usage() {
  printf 'usage: %s [--ensure-tools]\n' "${0##*/}" >&2
}

ensure_only=0
if [ "${1:-}" = "--ensure-tools" ]; then
  ensure_only=1
elif [ "$#" -gt 0 ]; then
  usage
  exit 2
fi

linux_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' amd64 ;;
    aarch64|arm64) printf '%s\n' arm64 ;;
    *)
      printf 'неподдерживаемая архитектура: %s\n' "$(uname -m)" >&2
      return 1
      ;;
  esac
}

helm_sha() {
  case "$1" in
    amd64) printf '%s\n' f5355c79190951eed23c5432a3b920e071f4c00a64f75e077de0dd4cb7b294ea ;;
    arm64) printf '%s\n' 5bd34ed774df6914b323ff84a0a156ea6ff2ba1eaf0113962fa773f3f9def798 ;;
    *)
      printf 'нет sha256 helm для архитектуры %s\n' "$1" >&2
      return 1
      ;;
  esac
}

kubeconform_sha() {
  case "$1" in
    amd64) printf '%s\n' 95f14e87aa28c09d5941f11bd024c1d02fdc0303ccaa23f61cef67bc92619d73 ;;
    arm64) printf '%s\n' dc82f79bb03c5479b1ae5fd4af221e4b5a3111f62bf01a2795d9c5c20fa96644 ;;
    *)
      printf 'нет sha256 kubeconform для архитектуры %s\n' "$1" >&2
      return 1
      ;;
  esac
}

prepend_local_bin() {
  local dest="${HOME}/.local/bin"
  mkdir -p "$dest"
  case ":${PATH}:" in
    *":${dest}:"*) ;;
    *) PATH="${dest}:${PATH}" ;;
  esac
  export PATH
}

helm_ok() {
  local v
  command -v helm >/dev/null 2>&1 || return 1
  v="$(helm version --short 2>/dev/null || true)"
  case "$v" in
    "${HELM_VERSION}"|"${HELM_VERSION}"+*) return 0 ;;
    *) return 1 ;;
  esac
}

kubeconform_ok() {
  local v
  command -v kubeconform >/dev/null 2>&1 || return 1
  v="$(kubeconform -v 2>&1 || true)"
  case "$v" in
    *"${KUBECONFORM_VERSION}") return 0 ;;
    *) return 1 ;;
  esac
}

# $1 url, $2 sha256 архива, $3 путь файла внутри архива, $4 имя бинаря в ~/.local/bin
install_tar_bin() {
  local url="$1" sha="$2" inner="$3" bin="$4"
  local tmp="${TMPDIR:-/tmp}/lint-manifests.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp" "${HOME}/.local/bin"
  if ! curl -fsSL --retry 3 -o "${tmp}/archive.tar.gz" "$url"; then
    rm -rf "$tmp"
    printf 'не удалось скачать %s\n' "$url" >&2
    exit 1
  fi
  if ! printf '%s  %s\n' "$sha" "${tmp}/archive.tar.gz" | sha256sum -c -; then
    rm -rf "$tmp"
    printf 'sha256 не совпал: %s\n' "$url" >&2
    exit 1
  fi
  tar -xzf "${tmp}/archive.tar.gz" -C "$tmp" "$inner"
  install -m 0755 "${tmp}/${inner}" "${HOME}/.local/bin/${bin}"
  rm -rf "$tmp"
  hash -r
}

ensure_helm() {
  if helm_ok; then
    return 0
  fi
  local arch sha
  arch="$(linux_arch)"
  sha="$(helm_sha "$arch")"
  printf 'ставлю helm %s в %s\n' "$HELM_VERSION" "${HOME}/.local/bin"
  install_tar_bin \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" \
    "$sha" \
    "linux-${arch}/helm" \
    helm
  if ! helm_ok; then
    printf 'helm %s не запускается после установки\n' "$HELM_VERSION" >&2
    exit 1
  fi
}

ensure_kubeconform() {
  if kubeconform_ok; then
    return 0
  fi
  local arch sha
  arch="$(linux_arch)"
  sha="$(kubeconform_sha "$arch")"
  printf 'ставлю kubeconform %s в %s\n' "$KUBECONFORM_VERSION" "${HOME}/.local/bin"
  install_tar_bin \
    "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-${arch}.tar.gz" \
    "$sha" \
    kubeconform \
    kubeconform
  if ! kubeconform_ok; then
    printf 'kubeconform %s не запускается после установки\n' "$KUBECONFORM_VERSION" >&2
    exit 1
  fi
}

prepend_local_bin
ensure_helm
ensure_kubeconform
printf 'helm %s\n' "$(helm version --short)"
printf 'kubeconform %s\n' "$(kubeconform -v 2>&1 | head -n 1)"

if [ "$ensure_only" -eq 1 ]; then
  exit 0
fi

schema='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
# Capabilities.APIVersions.Has в чарте сравнивает строку целиком с
# monitoring.coreos.com/v1/ServiceMonitor. Группы и версии недостаточно:
# ServiceMonitor тогда не попадает в рендер.
args=(-strict -summary -kubernetes-version 1.31.0 -schema-location default -schema-location "$schema")
api_versions=(
  --api-versions monitoring.coreos.com/v1
  --api-versions monitoring.coreos.com/v1/ServiceMonitor
)

printf '%s\n' 'kubeconform: stable'
helm template sensor deploy/helm/sensor-gateway \
  --namespace sensor \
  "${api_versions[@]}" \
  | kubeconform "${args[@]}"

printf '%s\n' 'kubeconform: canary'
helm template sensor-canary deploy/helm/sensor-gateway \
  --namespace sensor \
  "${api_versions[@]}" \
  --set track=canary \
  --set canary.enabled=true \
  --set canary.weight=10 \
  | kubeconform "${args[@]}"

# values-kube-prometheus-stack.yaml — values Helm, не манифест.
printf '%s\n' 'kubeconform: monitoring'
kubeconform "${args[@]}" \
  deploy/monitoring/dashboard-configmap.yaml \
  deploy/monitoring/prometheusrule.yaml

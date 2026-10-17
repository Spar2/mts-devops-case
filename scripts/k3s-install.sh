#!/usr/bin/env bash
# Idempotent cluster bootstrap.
# Default: k3s v1.31.4+k3s1, traefik off, ServiceLB on, kubeconfig mode 600 (копия для пользователя в ~/.kube/config, 600).
# K3D=1: k3d cluster "mts" (rancher/k3s:v1.31.4-k3s1, host port 8081 -> LB 80).
# Then Helm 3.16.3 if missing, and ingress-nginx 4.11.3 as a LoadBalancer
# without hostNetwork (k3s ServiceLB publishes it).
set -euo pipefail

K3S_VERSION="v1.31.4+k3s1"
K3S_IMAGE="rancher/k3s:v1.31.4-k3s1"
HELM_VERSION="v3.16.3"
KUBECTL_VERSION="v1.31.4"
K3D_VERSION="v5.8.3"
INGRESS_NGINX_VERSION="4.11.3"
INGRESS_NGINX_REPO="https://kubernetes.github.io/ingress-nginx"
K3D="${K3D:-0}"

linux_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *)
      echo "unsupported architecture: $(uname -m)" >&2
      return 1
      ;;
  esac
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_helm() {
  if [[ "$(helm version --short 2>/dev/null)" == "${HELM_VERSION}"* ]]; then
    echo "helm ${HELM_VERSION} present"
    return 0
  fi
  local arch tmp
  arch="$(linux_arch)"
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/helm.tgz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz"
  tar -xzf "${tmp}/helm.tgz" -C "${tmp}"
  run_root install -m 0755 "${tmp}/linux-${arch}/helm" /usr/local/bin/helm
  rm -rf "${tmp}"
  hash -r
  echo "installed helm ${HELM_VERSION}"
}

install_kubectl() {
  if kubectl version --client 2>/dev/null | grep -q "Client Version: ${KUBECTL_VERSION}$"; then
    echo "kubectl ${KUBECTL_VERSION} present"
    return 0
  fi
  local arch tmp
  arch="$(linux_arch)"
  tmp="$(mktemp)"
  curl -fsSL -o "${tmp}" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"
  run_root install -m 0755 "${tmp}" /usr/local/bin/kubectl
  rm -f "${tmp}"
  hash -r
  echo "installed kubectl ${KUBECTL_VERSION}"
}

install_k3d() {
  if k3d version 2>/dev/null | grep -q "^k3d version ${K3D_VERSION}$"; then
    echo "k3d ${K3D_VERSION} present"
    return 0
  fi
  local arch tmp
  arch="$(linux_arch)"
  tmp="$(mktemp)"
  curl -fsSL -o "${tmp}" "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-${arch}"
  run_root install -m 0755 "${tmp}" /usr/local/bin/k3d
  rm -f "${tmp}"
  hash -r
  echo "installed k3d ${K3D_VERSION}"
}

k3s_matches() {
  command -v k3s >/dev/null 2>&1 || return 1
  [[ "$(k3s --version 2>/dev/null | awk '{print $3}')" == "${K3S_VERSION}" ]] || return 1
  local blob=""
  if [[ -f /etc/systemd/system/k3s.service ]]; then
    blob+="$(cat /etc/systemd/system/k3s.service)"
  fi
  if [[ -f /etc/rancher/k3s/config.yaml ]]; then
    blob+="$(cat /etc/rancher/k3s/config.yaml)"
  fi
  # systemd splits flags across lines (`--disable` then `traefik`). Match on one line.
  local flat
  flat="$(printf '%s' "${blob}" | tr '\n' ' ')"
  grep -Eq -- 'disable[^[:alnum:]]+traefik' <<<"${flat}" || return 1
  grep -Eq -- 'write-kubeconfig-mode[^0-9]*600' <<<"${flat}" || return 1
  return 0
}

install_k3s() {
  if k3s_matches; then
    echo "k3s ${K3S_VERSION} already installed (traefik disabled)"
  else
    echo "installing k3s ${K3S_VERSION}"
    # ServiceLB stays enabled so LoadBalancer Services get an address.
    if [[ "$(id -u)" -eq 0 ]]; then
      curl -sfL https://get.k3s.io | env INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - \
        --disable traefik \
        --write-kubeconfig-mode 600
    else
      curl -sfL https://get.k3s.io | sudo env INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - \
        --disable traefik \
        --write-kubeconfig-mode 600
    fi
  fi
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    # Админ-kubeconfig не должен читаться всеми пользователями хоста.
    run_root chmod 600 /etc/rancher/k3s/k3s.yaml
    mkdir -p "${HOME}/.kube"
    run_root install -m 600 -o "$(id -u)" -g "$(id -g)" /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
  fi
  if [[ ! -e /usr/local/bin/kubectl ]]; then
    run_root ln -s /usr/local/bin/k3s /usr/local/bin/kubectl
    hash -r
  fi
  if command -v systemctl >/dev/null 2>&1; then
    run_root systemctl enable --now k3s
  fi
  export KUBECONFIG="${HOME}/.kube/config"
}

k3d_cluster_exists() {
  k3d cluster list -o json 2>/dev/null | grep -Eq '"name"[[:space:]]*:[[:space:]]*"mts"'
}

k3d_server_running() {
  docker ps --format '{{.Names}}' | grep -qx 'k3d-mts-server-0'
}

install_k3d_cluster() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "K3D=1 requires docker" >&2
    exit 1
  fi
  install_k3d
  install_kubectl
  if k3d_cluster_exists; then
    echo "k3d cluster mts already exists"
    if k3d_server_running; then
      echo "k3d cluster mts is already running"
    else
      k3d cluster start mts
    fi
  else
    # K3D_EXTRA_ARGS: e.g. "--k3s-arg --flannel-backend=host-gw@server:0" where vxlan is unavailable.
    # shellcheck disable=SC2086
    k3d cluster create mts \
      --image "${K3S_IMAGE}" \
      --k3s-arg "--disable=traefik@server:0" \
      ${K3D_EXTRA_ARGS:-} \
      -p "8081:80@loadbalancer" \
      --kubeconfig-switch-context \
      --wait
  fi
  mkdir -p "${HOME}/.kube"
  export KUBECONFIG="${HOME}/.kube/config"
  k3d kubeconfig merge mts --kubeconfig-merge-default --kubeconfig-switch-context
  kubectl config use-context k3d-mts >/dev/null
  if [[ "${K3D_PRELOAD:-0}" == "1" ]]; then
    "$(dirname "$0")/k3d-preload-images.sh"
  fi
}

wait_for_cluster() {
  local i
  for i in $(seq 1 60); do
    if kubectl get --raw=/readyz >/dev/null 2>&1; then
      break
    fi
    if [[ "${i}" -eq 60 ]]; then
      echo "kubernetes API is not reachable (KUBECONFIG=${KUBECONFIG:-})" >&2
      return 1
    fi
    sleep 2
  done
  kubectl wait --for=condition=Ready nodes --all --timeout=180s
}

install_ingress_nginx() {
  if helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx ingress-nginx; then
    helm repo add ingress-nginx "${INGRESS_NGINX_REPO}" --force-update
  else
    helm repo add ingress-nginx "${INGRESS_NGINX_REPO}"
  fi
  helm repo update ingress-nginx || helm repo update
  # Controller is a Deployment with a LoadBalancer Service, not hostNetwork.
  # k3s ServiceLB (left enabled) assigns the external address.
  local digest_args=()
  if [[ "${K3D_PRELOAD:-0}" == "1" ]]; then
    # Preloaded images are imported by tag; digest-pinned refs would force a registry pull.
    digest_args=(--set controller.image.digest= --set controller.admissionWebhooks.patch.image.digest=)
  fi
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    "${digest_args[@]}" \
    --version "${INGRESS_NGINX_VERSION}" \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.kind=Deployment \
    --set controller.metrics.enabled=true \
    --set controller.hostNetwork=false \
    --set controller.dnsPolicy=ClusterFirst \
    --set controller.service.type="${INGRESS_SERVICE_TYPE:-LoadBalancer}" \
    --set controller.ingressClassResource.name=nginx \
    --set controller.ingressClass=nginx \
    --set controller.ingressClassResource.default=true \
    --wait \
    --timeout 10m
  wait_for_admission_webhook
}

# The admission webhook gets its CA from a post-install Job. Until the CA is
# patched in, every Ingress create fails with "x509: unknown authority".
# Retry a server-side dry-run Ingress until the webhook accepts it.
wait_for_admission_webhook() {
  local probe i
  probe="$(mktemp)"
  cat >"${probe}" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: webhook-probe
  namespace: default
spec:
  ingressClassName: nginx
  rules:
    - host: webhook-probe.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: none
                port:
                  number: 80
YAML
  for i in $(seq 1 60); do
    if kubectl apply --dry-run=server -f "${probe}" >/dev/null 2>&1; then
      rm -f "${probe}"
      echo "ingress-nginx admission webhook ready"
      return 0
    fi
    sleep 3
  done
  rm -f "${probe}"
  echo "ingress-nginx admission webhook not ready after 180s" >&2
  return 1
}

# Проверки окружения до любых установок: понятная ошибка вместо падения на середине.
check_prereqs() {
  local missing=()
  local cmd
  for cmd in curl openssl sha256sum tar git; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if [[ "${K3D}" == "1" ]]; then
    command -v docker >/dev/null 2>&1 || missing+=("docker")
    if command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
      echo "docker установлен, но недоступен текущему пользователю: sudo usermod -aG docker \"${USER}\" и перелогиниться" >&2
      exit 1
    fi
  fi
  if ((${#missing[@]})); then
    echo "Не хватает: ${missing[*]}. Установить: sudo apt-get install -y ${missing[*]/docker/docker.io}" >&2
    exit 1
  fi
}

# *.localtest.me публично резолвится в 127.0.0.1. Если DNS этого не делает (split DNS, офлайн),
# добавляем строку в /etc/hosts, иначе smoke и ingress не заработают.
ensure_hosts() {
  local host
  for host in sensor.localtest.me grafana.localtest.me; do
    if [[ "$(getent ahostsv4 "${host}" | awk 'NR==1 {print $1}')" != "127.0.0.1" ]]; then
      echo "${host} не резолвится в 127.0.0.1, добавляю в /etc/hosts"
      echo "127.0.0.1 ${host}" | run_root tee -a /etc/hosts >/dev/null
    fi
  done
}

check_prereqs
ensure_hosts
install_helm
if [[ "${K3D}" == "1" ]]; then
  install_k3d_cluster
else
  install_k3s
fi
wait_for_cluster
install_ingress_nginx

echo "ready KUBECONFIG=${KUBECONFIG} ingress-nginx=${INGRESS_NGINX_VERSION}"
if [[ "${K3D}" == "1" ]]; then
  echo "k3d loadbalancer: http://sensor.localtest.me:8081"
fi

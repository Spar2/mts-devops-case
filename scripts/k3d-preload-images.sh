#!/usr/bin/env bash
# Для стендов, где поды не могут сами скачать образы (закрытый egress, песочница):
# тянет образы на хосте и импортирует их в k3d-кластер "mts".
# Обычная Ubuntu с интернетом этот шаг не требует.
set -euo pipefail
cluster="${K3D_CLUSTER:-mts}"
images=(
  rancher/mirrored-pause:3.6
  rancher/mirrored-coredns-coredns:1.12.0
  rancher/local-path-provisioner:v0.0.30
  rancher/klipper-lb:v0.4.9
  registry.k8s.io/ingress-nginx/controller:v1.11.3
  registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.4
  docker.io/grafana/grafana:11.2.1
  quay.io/kiwigrid/k8s-sidecar:1.27.4
  quay.io/prometheus-operator/prometheus-operator:v0.77.1
  quay.io/prometheus-operator/prometheus-config-reloader:v0.77.1
  quay.io/prometheus/alertmanager:v0.27.0
  quay.io/prometheus/node-exporter:v1.8.2
  quay.io/prometheus/prometheus:v2.54.1
  registry.k8s.io/ingress-nginx/kube-webhook-certgen:v20221220-controller-v1.5.1-58-g787ea74b6
  registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0
)
for image in "${images[@]}"; do
  docker image inspect "${image}" >/dev/null 2>&1 || docker pull -q "${image}"
done
k3d image import -c "${cluster}" "${images[@]}"

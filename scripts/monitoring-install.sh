#!/usr/bin/env bash
# Install kube-prometheus-stack 65.1.1, the sensor-gateway dashboard and alerts,
# and the alert-sink webhook Deployment. The namespace comes from Helm.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
values="${root}/deploy/monitoring/values-kube-prometheus-stack.yaml"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update prometheus-community

helm upgrade --install mon prometheus-community/kube-prometheus-stack \
  --version 65.1.1 \
  -n monitoring \
  --create-namespace \
  -f "${values}" \
  --wait \
  --timeout 10m

kubectl apply -f "${root}/deploy/monitoring/dashboard-configmap.yaml"
kubectl apply -f "${root}/deploy/monitoring/prometheusrule.yaml"
kubectl apply -f "${root}/deploy/monitoring/alert-sink.yaml"
kubectl -n monitoring rollout status deployment/alert-sink --timeout=180s

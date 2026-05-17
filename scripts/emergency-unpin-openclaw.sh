#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
APP_NAMESPACE="${APP_NAMESPACE:-argocd}"
APP_NAME="${APP_NAME:-openclaw}"
TARGET_REVISION="${1:-main}"

echo "Unpinning Argo app $APP_NAMESPACE/$APP_NAME targetRevision=$TARGET_REVISION"
kubectl -n "$APP_NAMESPACE" patch application "$APP_NAME" --type=merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"$TARGET_REVISION\"}}}"
kubectl -n "$APP_NAMESPACE" annotate application "$APP_NAME" \
  argocd.argoproj.io/refresh=hard --overwrite

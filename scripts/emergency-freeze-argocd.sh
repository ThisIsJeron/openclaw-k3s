#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
APP_NAMESPACE="${APP_NAMESPACE:-argocd}"
APP_NAME="${APP_NAME:-openclaw}"

cat <<MSG
This script documents the manual freeze step.
For this app, the practical freeze is to pin targetRevision to a SHA instead of main.
Run:
  scripts/emergency-rollback-openclaw.sh <sha|lkg>

Current app source:
MSG
kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.spec.source}{"\n"}'

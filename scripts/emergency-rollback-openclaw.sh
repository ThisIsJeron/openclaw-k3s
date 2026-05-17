#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
APP_NAMESPACE="${APP_NAMESPACE:-argocd}"
APP_NAME="${APP_NAME:-openclaw}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-openclaw}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-openclaw}"
SERVICE_NAME="${SERVICE_NAME:-openclaw}"
SERVICE_PORT="${SERVICE_PORT:-18789}"
LKG_CONFIGMAP="${LKG_CONFIGMAP:-openclaw-last-known-good}"
REVISION="${1:-lkg}"
TIMEOUT="${TIMEOUT:-300s}"
VERIFY_SLACK="${VERIFY_SLACK:-0}"

log() { printf '[rollback] %s\n' "$*"; }
die() { printf '[rollback] ERROR: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
need kubectl

current_target="$(kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null || true)"
current_sync="$(kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
current_health="$(kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
current_revision="$(kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
log "current target=${current_target:-unknown} revision=${current_revision:-unknown} sync=${current_sync:-unknown} health=${current_health:-unknown}"

if [[ "$REVISION" == "lkg" ]]; then
  REVISION="$(kubectl -n "$TARGET_NAMESPACE" get configmap "$LKG_CONFIGMAP" -o jsonpath='{.data.revision}' 2>/dev/null || true)"
fi

[[ -n "$REVISION" ]] || die "No rollback revision supplied and no LKG found"

log "patching Argo app $APP_NAMESPACE/$APP_NAME targetRevision=$REVISION"
kubectl -n "$APP_NAMESPACE" patch application "$APP_NAME" --type=merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"$REVISION\"}}}"
kubectl -n "$APP_NAMESPACE" annotate application "$APP_NAME" \
  argocd.argoproj.io/refresh=hard --overwrite

# Automated sync should reconcile the pin. If Argo is idle, request an immediate sync too.
if kubectl -n "$APP_NAMESPACE" patch application "$APP_NAME" --type=merge \
  -p "{\"operation\":{\"sync\":{\"revision\":\"$REVISION\",\"prune\":true}}}" >/dev/null 2>&1; then
  log "requested immediate Argo sync operation"
else
  log "immediate sync operation request was skipped/blocked; relying on automated sync"
fi

log "waiting for OpenClaw rollout ($TIMEOUT)"
kubectl -n "$TARGET_NAMESPACE" rollout status "deploy/$DEPLOYMENT_NAME" --timeout="$TIMEOUT"

log "verifying pod readiness"
kubectl -n "$TARGET_NAMESPACE" get pod -l "app.kubernetes.io/name=$DEPLOYMENT_NAME" -o wide
bad_pods="$(kubectl -n "$TARGET_NAMESPACE" get pods -l "app.kubernetes.io/name=$DEPLOYMENT_NAME" --no-headers 2>/dev/null | grep -E 'Init:Error|Init:CrashLoopBackOff|CrashLoopBackOff|ImagePullBackOff|CreateContainerConfigError|ErrImagePull|RunContainerError' || true)"
[[ -z "$bad_pods" ]] || die "bad pod state after rollback: $bad_pods"

log "verifying /readyz through Kubernetes service proxy"
readyz="$(kubectl get --raw "/api/v1/namespaces/${TARGET_NAMESPACE}/services/http:${SERVICE_NAME}:${SERVICE_PORT}/proxy/readyz" 2>/dev/null || true)"
if ! printf '%s' "$readyz" | grep -Eq '^ok|"ready"[[:space:]]*:[[:space:]]*true'; then
  die "/readyz failed after rollback: ${readyz:-<empty>}"
fi

final_target="$(kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null || true)"
final_revision="$(kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
final_sync="$(kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
final_health="$(kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
log "final target=${final_target:-unknown} revision=${final_revision:-unknown} sync=${final_sync:-unknown} health=${final_health:-unknown} readyz=ok"

if [[ "$VERIFY_SLACK" == "1" ]]; then
  if [[ -x "$(dirname "$0")/slack-bridge-health.sh" ]]; then
    "$(dirname "$0")/slack-bridge-health.sh" --canary || die "Slack bridge verification failed"
  else
    die "VERIFY_SLACK=1 requested but scripts/slack-bridge-health.sh is missing"
  fi
fi

log "rollback verification complete"

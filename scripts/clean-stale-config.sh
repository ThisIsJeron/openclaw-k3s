#!/usr/bin/env bash
# Overwrite the openclaw PVC's openclaw.json with the fresh
# ConfigMap-rendered copy from /config-work. This eliminates the trap
# where init containers that don't set OPENCLAW_CONFIG_PATH fall back
# to a stale workspace/plugin config on the PVC and crash on
# validation (the better-gateway-dev incident, 2026-05-13).
#
# Idempotent. Safe to run on a healthy pod. Verifies the new file
# parses as JSON before declaring success.

set -euo pipefail

NAMESPACE="${NAMESPACE:-openclaw}"
SELECTOR="${SELECTOR:-app.kubernetes.io/name=openclaw}"

log() { printf '[clean-stale-config] %s\n' "$*"; }
die() { printf '[clean-stale-config] ERROR: %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"

pod="$(kubectl -n "$NAMESPACE" get pod -l "$SELECTOR" \
  -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' \
  | awk '{print $1}')"

[ -n "$pod" ] || die "no Running openclaw pod found in namespace $NAMESPACE"

log "target pod: $pod"
log "diffing live PVC config vs ConfigMap-rendered config…"
kubectl -n "$NAMESPACE" exec "$pod" -c openclaw -- sh -c '
  set -e
  pvc=/home/node/.openclaw/openclaw.json
  fresh=/config-work/openclaw.json
  if [ ! -f "$pvc" ]; then
    echo "no stale config at $pvc; nothing to clean"
    exit 0
  fi
  if [ ! -f "$fresh" ]; then
    echo "fresh config $fresh not found; aborting" >&2
    exit 1
  fi
  if diff -q "$pvc" "$fresh" >/dev/null 2>&1; then
    echo "$pvc already matches $fresh; nothing to do"
    exit 0
  fi
  # Validate fresh config parses
  node -e "JSON.parse(require(\"fs\").readFileSync(\"$fresh\",\"utf8\"))"
  # Save a backup so a manual revert is possible
  ts=$(date +%Y%m%dT%H%M%S)
  cp "$pvc" "${pvc}.bak-${ts}"
  cp "$fresh" "$pvc"
  echo "replaced $pvc with $fresh (backup at ${pvc}.bak-${ts})"
'

log "done"

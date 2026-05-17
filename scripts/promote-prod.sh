#!/usr/bin/env bash
# Bump argocd/application.yaml to a new pinned SHA so ArgoCD deploys it.
#
# This is the "promotion" step in promotion-based GitOps: a push to main
# does not auto-deploy. Prod only moves forward when this script runs and
# the resulting commit is merged + kubectl applied.
#
# Usage:
#   scripts/promote-prod.sh HEAD            # promote current local HEAD
#   scripts/promote-prod.sh <sha-or-ref>    # promote a specific commit
#
# The script refuses to promote a SHA that's not reachable from
# origin/main, so you can't accidentally promote a feature branch.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Post app-of-apps migration: this is the child Application managed by
# argocd/root/root.yaml. Bumping targetRevision here flows into the
# cluster automatically via ArgoCD's reconciliation of the root app —
# no `kubectl apply` step needed after this commit lands on main.
APP_FILE="$ROOT/argocd/apps/openclaw.yaml"

if [ $# -lt 1 ]; then
  sed -n '3,15p' "$0"
  exit 2
fi

ref="$1"
target_sha="$(git -C "$ROOT" rev-parse --verify "$ref^{commit}")"
short_sha="$(git -C "$ROOT" rev-parse --short "$target_sha")"

git -C "$ROOT" fetch --quiet origin main
if ! git -C "$ROOT" merge-base --is-ancestor "$target_sha" origin/main; then
  echo "ERROR: $short_sha is not an ancestor of origin/main" >&2
  echo "Refusing to promote a SHA that isn't on main." >&2
  exit 1
fi

current="$(awk '/^[[:space:]]*targetRevision:/ {print $2; exit}' "$APP_FILE")"
if [ "$current" = "$target_sha" ]; then
  echo "[promote] argocd/application.yaml already targets $short_sha. Nothing to do."
  exit 0
fi

# Use awk for portability (macOS BSD sed and GNU sed differ on -i)
tmp="$(mktemp)"
awk -v new="$target_sha" '
  /^[[:space:]]*targetRevision:/ && !done {
    sub(/targetRevision:.*/, "targetRevision: " new)
    done = 1
  }
  { print }
' "$APP_FILE" > "$tmp"
mv "$tmp" "$APP_FILE"

echo "[promote] argocd/application.yaml: $(printf '%s' "$current" | cut -c1-7) → $short_sha"
echo ""
git -C "$ROOT" --no-pager diff -- "$APP_FILE"
echo ""
echo "Next steps:"
echo "  1. Review the diff above and the rendered chart at $short_sha."
echo "  2. Commit:   git -C $ROOT commit -am 'Promote prod to $short_sha'"
echo "  3. Push:     git -C $ROOT push origin main"
echo ""
echo "ArgoCD's openclaw-root will detect the bump and sync prod to $short_sha"
echo "within ~1 minute. No kubectl apply needed (root tracks main HEAD)."
echo "Watch:"
echo "  kubectl get pods -n openclaw -l app.kubernetes.io/name=openclaw -w"

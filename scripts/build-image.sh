#!/usr/bin/env bash
# Build and push the baked openclaw image to the Forgejo registry.
#
# Use this until the Forgejo Actions runner is set up; once a runner exists,
# .forgejo/workflows/image.yml does the same thing on every push.
#
# Usage:
#   scripts/build-image.sh                 # build HEAD for linux/amd64
#   PLATFORMS=linux/amd64,linux/arm64 \
#     scripts/build-image.sh               # multi-arch (slower from arm64 macs)
#   scripts/build-image.sh --dirty         # allow a dirty working tree

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${REGISTRY:-ghcr.io}"
IMAGE="${IMAGE:-YOUR_GITHUB_ORG/openclaw}"
PLATFORMS="${PLATFORMS:-linux/amd64}"
CONTEXT="${CONTEXT:-$ROOT/chart/openclaw/image}"
DOCKERFILE="${DOCKERFILE:-$CONTEXT/Dockerfile}"
ALLOW_DIRTY=0

for arg in "$@"; do
  case "$arg" in
    --dirty) ALLOW_DIRTY=1 ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

log() { printf '[build-image] %s\n' "$*"; }
die() { printf '[build-image] ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
docker info >/dev/null 2>&1 || die "docker daemon is not running"
docker buildx version >/dev/null 2>&1 || die "docker buildx plugin missing"

config="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
if [ ! -f "$config" ] || ! grep -q "\"$REGISTRY\"" "$config"; then
  die "not logged in to $REGISTRY. Run:  docker login $REGISTRY"
fi

cd "$ROOT"
if [ "$ALLOW_DIRTY" -ne 1 ] && ! git diff-index --quiet HEAD --; then
  die "working tree has uncommitted changes. Commit first, or pass --dirty."
fi

short_sha="$(git rev-parse --short HEAD)"
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$ALLOW_DIRTY" -eq 1 ] && short_sha="${short_sha}-dirty"

tag_sha="$REGISTRY/$IMAGE:$short_sha"
tag_branch="$REGISTRY/$IMAGE:$branch"

log "building $tag_sha for $PLATFORMS"
log "  context:    $CONTEXT"
log "  dockerfile: $DOCKERFILE"

# Use a fresh builder so we don't conflict with other docker buildx workflows
builder="openclaw-builder"
if ! docker buildx inspect "$builder" >/dev/null 2>&1; then
  docker buildx create --name "$builder" --use >/dev/null
else
  docker buildx use "$builder"
fi
docker buildx inspect --bootstrap >/dev/null

metadata_file="$(mktemp)"
trap 'rm -f "$metadata_file"' EXIT

docker buildx build \
  --platform "$PLATFORMS" \
  --push \
  --provenance=false \
  --tag "$tag_sha" \
  --tag "$tag_branch" \
  --metadata-file "$metadata_file" \
  --file "$DOCKERFILE" \
  "$CONTEXT"

digest="$(grep -o '"containerimage.digest":[[:space:]]*"sha256:[a-f0-9]*"' "$metadata_file" \
            | head -1 \
            | sed -E 's/.*"(sha256:[a-f0-9]*)"/\1/')"
[ -n "$digest" ] || die "could not parse image digest from buildx metadata"

cat <<EOF

[build-image] DONE

Tags pushed:
  $tag_sha
  $tag_branch

Digest: $digest

Paste into chart/openclaw/values.yaml:

image:
  repository: $REGISTRY/$IMAGE
  digest: $digest
  pullPolicy: IfNotPresent
  bakedTools: true
  pullSecrets:
    - name: forgejo-registry

Make sure the openclaw namespace has the pull secret:

  kubectl create secret docker-registry forgejo-registry \\
    --namespace openclaw \\
    --docker-server=$REGISTRY \\
    --docker-username=<forgejo-user> \\
    --docker-password=<forgejo-token>
EOF

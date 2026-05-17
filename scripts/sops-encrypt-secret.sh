#!/usr/bin/env bash
# Encrypt a Kubernetes Secret manifest with sops + age and write it to
# chart/openclaw/secrets/. This is the source-side helper for the
# in-Git encrypted secrets workflow documented in docs/SECRETS-SOPS.md.
#
# Usage:
#   scripts/sops-encrypt-secret.sh <plaintext-secret.yaml> [output-name]
#
# Reads the recipient age public keys from .sops.yaml at the repo
# root, which selects encryption rules by path. Plaintext input is
# read once and never written to disk by this script.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$ROOT/chart/openclaw/secrets"

if [ $# -lt 1 ]; then
  echo "usage: $0 <plaintext-secret.yaml> [output-name]" >&2
  echo "" >&2
  echo "Example:" >&2
  echo "  cat <<YAML | $0 - openclaw-secrets.enc.yaml" >&2
  echo "  apiVersion: v1" >&2
  echo "  kind: Secret" >&2
  echo "  metadata:" >&2
  echo "    name: openclaw-secrets" >&2
  echo "    namespace: openclaw" >&2
  echo "  stringData:" >&2
  echo "    OPENAI_API_KEY: sk-..." >&2
  echo "  YAML" >&2
  exit 2
fi

input="$1"
output_name="${2:-}"

command -v sops >/dev/null 2>&1 || {
  echo "ERROR: sops not found in PATH" >&2
  echo "Install with: brew install sops  (or your distro's package manager)" >&2
  exit 1
}

if [ ! -f "$ROOT/.sops.yaml" ]; then
  echo "ERROR: $ROOT/.sops.yaml missing — see docs/SECRETS-SOPS.md to bootstrap age key" >&2
  exit 1
fi

mkdir -p "$SECRETS_DIR"

if [ -z "$output_name" ]; then
  if [ "$input" = "-" ]; then
    echo "ERROR: must provide an output-name when reading from stdin" >&2
    exit 2
  fi
  base="$(basename "$input")"
  base="${base%.yaml}"
  output_name="${base}.enc.yaml"
fi

# Strip any .enc.yaml/.yaml accident from the user-provided name
case "$output_name" in
  *.enc.yaml) ;;
  *.yaml) output_name="${output_name%.yaml}.enc.yaml" ;;
  *) output_name="${output_name}.enc.yaml" ;;
esac

out_path="$SECRETS_DIR/$output_name"

if [ "$input" = "-" ]; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  cat > "$tmp"
  input="$tmp"
fi

sops --encrypt \
  --input-type yaml --output-type yaml \
  "$input" > "$out_path"

echo "Wrote encrypted manifest to:"
echo "  $out_path"
echo ""
echo "Verify it decrypts (requires age private key on this machine):"
echo "  sops --decrypt $out_path"
echo ""
echo "Then commit:"
echo "  git add $out_path"
echo "  git commit -m 'Add encrypted ${output_name%.enc.yaml} secret'"

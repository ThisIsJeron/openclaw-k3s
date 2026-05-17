#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${CHART_DIR:-$ROOT/chart/openclaw}"
RENDERED="${RENDERED:-$(mktemp)}"
SKIP_NPM_VIEW="${SKIP_NPM_VIEW:-0}"

NATIVE_CHANNEL_PACKAGES=(
  "@openclaw/slack"
  "@openclaw/telegram"
  "@openclaw/whatsapp"
  "@openclaw/signal"
)

log() { printf '[preflight] %s\n' "$*"; }
die() { printf '[preflight] ERROR: %s\n' "$*" >&2; exit 1; }

command -v helm >/dev/null 2>&1 || die "helm is required"
command -v awk >/dev/null 2>&1 || die "awk is required"

SECRETS_DIR="$CHART_DIR/secrets"
if [[ -d "$SECRETS_DIR" ]]; then
  bad_secret_files=()
  while IFS= read -r -d '' f; do
    name="$(basename "$f")"
    case "$name" in
      .gitignore|.gitkeep|*.enc.yaml) ;;
      *) bad_secret_files+=("$f") ;;
    esac
  done < <(find "$SECRETS_DIR" -type f -print0)

  if [[ ${#bad_secret_files[@]} -gt 0 ]]; then
    printf '%s\n' "${bad_secret_files[@]}" >&2
    die "plaintext/non-SOPS files found under $SECRETS_DIR; only *.enc.yaml is allowed"
  fi

  if find "$SECRETS_DIR" -type f -name '*.enc.yaml' | grep -q . && [[ ! -f "$ROOT/.sops.yaml" ]]; then
    die "encrypted secret manifests exist but $ROOT/.sops.yaml is missing"
  fi
fi

log "helm lint $CHART_DIR"
helm lint "$CHART_DIR" >/dev/null

log "helm template $CHART_DIR"
helm template openclaw "$CHART_DIR" --namespace openclaw >"$RENDERED"

mapfile -t plugins < <(
  awk '
    /ensure_plugin[[:space:]]+/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "ensure_plugin" && (i + 2) <= NF) {
          gsub(/"|\047/, "", $(i+1));
          gsub(/"|\047/, "", $(i+2));
          print $(i+1) "@" $(i+2);
        }
      }
    }
  ' "$RENDERED" | sort -u
)

# Under image.bakedTools=true the chart skips install-channel-plugins
# (no ensure_plugin lines render) and uses seed-plugins instead. Detect
# either path; only fail if neither is present.
if [[ ${#plugins[@]} -eq 0 ]]; then
  if grep -q 'name: seed-plugins' "$RENDERED"; then
    log "rendered chart uses seed-plugins (bakedTools=true); no npm preflight required"
  else
    die "no ensure_plugin lines AND no seed-plugins init container found in rendered chart; plugin install preflight may be blind"
  fi
else
  log "rendered plugin installs: ${plugins[*]}"
fi

if [[ ${#plugins[@]} -gt 0 ]]; then
for pkgver in "${plugins[@]}"; do
  pkg="${pkgver%@*}"
  ver="${pkgver##*@}"
  for native in "${NATIVE_CHANNEL_PACKAGES[@]}"; do
    if [[ "$pkg" == "$native" ]]; then
      die "$pkg is a native channel, not an npm plugin; remove it from install-channel-plugins"
    fi
  done
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)?$ ]] || die "$pkg has suspicious version '$ver'"
  if [[ "$SKIP_NPM_VIEW" != "1" ]]; then
    log "npm view $pkg@$ver"
    npm view "$pkg@$ver" version >/dev/null || die "npm package not published/resolvable: $pkg@$ver"
  fi
done
fi

if grep -RIn --exclude-dir=.git --exclude='*.md' '@openclaw/slack' "$ROOT/chart" "$ROOT/argocd" >/tmp/openclaw-slack-grep 2>/dev/null; then
  cat /tmp/openclaw-slack-grep >&2
  die "@openclaw/slack appears in rendered/deployable files; Slack is native and must not be installed as a plugin"
fi
rm -f /tmp/openclaw-slack-grep

log "OK"

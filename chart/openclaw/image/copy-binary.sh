#!/bin/sh
# Copy a binary plus its dynamic library deps into a /bin + /lib layout
# under the given destination root. Mirrors the inline copy_binary() helper
# in chart/openclaw/templates/deployment.yaml (install-runtime-tools init
# container) so the baked image and the legacy init container path stay
# byte-compatible.
set -eu

dest_root="${1:?dest_root required}"
name="${2:?binary name required}"

src="$(command -v "$name")"
cp -L "$src" "${dest_root}/bin/$(basename "$src")"
chmod 0755 "${dest_root}/bin/$(basename "$src")"

ldd "$src" 2>/dev/null | awk '/=> \//{print $3} /^\//{print $1}' | sort -u | while read -r lib; do
  [ -n "$lib" ] || continue
  cp -L "$lib" "${dest_root}/lib/$(basename "$lib")"
done

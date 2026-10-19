#!/usr/bin/env bash
# Rebuild small installation archives from a committed revision, never a stale ZIP.
# Usage: bash packaging/build-installers.sh [revision [output-directory]]
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
revision="$(git -C "$REPO_DIR" rev-parse --verify "${1:-HEAD}^{commit}")"
output="${2:-$REPO_DIR/dist}"
if command -v sha256sum >/dev/null 2>&1; then checksum=(sha256sum);
else checksum=(shasum -a 256); fi
mkdir -p "$output"
output="$(cd -- "$output" && pwd)"
rm -f -- "$output/SHA256SUMS"
files=(install.sh uninstall.sh lib.sh autoconfig.sh fx-autoconfig.conf install.ps1
    JS/replace-new-tab.uc.js CSS/firefox-floating-urlbar.uc.css LICENSE ATTRIBUTION.md README.md)
for format in tar.gz zip; do
    git -C "$REPO_DIR" archive --format="$format" --prefix=firefox-floating-urlbar/ \
        --output="$output/firefox-floating-urlbar.$format" "$revision" -- "${files[@]}"
done
git -C "$REPO_DIR" archive --format=zip --prefix=firefox-floating-urlbar-manual/ \
    --output="$output/firefox-floating-urlbar-manual.zip" "$revision" -- \
    JS/replace-new-tab.uc.js CSS/firefox-floating-urlbar.uc.css LICENSE ATTRIBUTION.md README.md
checksums="$(cd -- "$output" && "${checksum[@]}" firefox-floating-urlbar.tar.gz \
    firefox-floating-urlbar.zip firefox-floating-urlbar-manual.zip)"
printf '%s\n' "$checksums" > "$output/SHA256SUMS"
printf 'Built installation archives from %s in %s\n' "$revision" "$output"

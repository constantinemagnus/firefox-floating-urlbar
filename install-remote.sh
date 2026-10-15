#!/usr/bin/env bash
# One-command installer for Linux and macOS (no Git checkout needed).
# Paste this; it downloads this repository, runs install.sh, and cleans up:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.sh)"
#
# A leading --uninstall runs uninstall.sh; other arguments pass through.
# Override the archive with FIREFOX_FLOATING_URLBAR_URL (mostly useful for tests).
set -euo pipefail

REPO_URL="${FIREFOX_FLOATING_URLBAR_URL:-https://codeload.github.com/constantinemagnus/firefox-floating-urlbar/tar.gz/refs/heads/main}"
installer=install.sh
if [[ "${1:-}" == --uninstall ]]; then
    installer=uninstall.sh
    shift
fi

command -v curl >/dev/null 2>&1 || { echo "Error: curl is required." >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "Error: tar is required." >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 \
    --output "$work/repo.tar.gz" "$REPO_URL"
tar -xzf "$work/repo.tar.gz" -C "$work"

roots=( "$work"/firefox-floating-urlbar-* )
[[ -d "${roots[0]}" ]] || { echo "Error: unexpected repository archive layout." >&2; exit 1; }

# No exec here: replacing the shell would skip the EXIT trap and leak $work.
bash "${roots[0]}/$installer" "$@"

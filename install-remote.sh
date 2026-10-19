#!/usr/bin/env bash
# One-command installer for Linux and macOS (no Git checkout needed).
# Paste this; it downloads the required files, runs install.sh, and cleans up:
#
#   installer=$(curl -fsSL https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.sh) && bash -c "$installer"
#
# A leading --uninstall runs uninstall.sh; other arguments pass through.
# Override the archive with FIREFOX_FLOATING_URLBAR_URL (mostly useful for tests).
set -euo pipefail

installer=install.sh
if [[ "${1:-}" == --uninstall ]]; then
    installer=uninstall.sh
    shift
fi

command -v curl >/dev/null 2>&1 || { echo "Error: curl is required." >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

download() {
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 "$@"
}

if [[ -n "${FIREFOX_FLOATING_URLBAR_URL:-}" ]]; then
    command -v tar >/dev/null 2>&1 || { echo "Error: tar is required." >&2; exit 1; }
    download --output "$work/repo.tar.gz" "$FIREFOX_FLOATING_URLBAR_URL"
    tar -xzf "$work/repo.tar.gz" -C "$work"
    roots=( "$work"/firefox-floating-urlbar* )
    [[ -d "${roots[0]}" ]] || { echo "Error: unexpected repository archive layout." >&2; exit 1; }
    root="${roots[0]}"
else
    echo "Downloading installer files..."
    # Resolve once so files cannot come from different commits during an update.
    revision="$(download --header 'Accept: application/vnd.github.sha' \
        https://api.github.com/repos/constantinemagnus/firefox-floating-urlbar/commits/main)"
    [[ "$revision" =~ ^[a-fA-F0-9]{40}$ ]] || { echo "Error: invalid repository revision." >&2; exit 1; }
    root="$work/firefox-floating-urlbar"
    mkdir -p "$root/JS" "$root/CSS"
    for file in install.sh uninstall.sh lib.sh autoconfig.sh fx-autoconfig.conf \
        JS/replace-new-tab.uc.js CSS/firefox-floating-urlbar.uc.css; do
        download --output "$root/$file" \
            "https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/$revision/$file"
    done
fi

# No exec here: replacing the shell would skip the EXIT trap and leak $work.
bash "$root/$installer" "$@"

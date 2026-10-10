#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<USAGE
Usage: ./install.sh [options] [PROFILE_DIR]

Tested on Linux. Windows and macOS users: see the manual install steps in the README.

Options:
  -p, --profile DIR   Install into this profile folder (skips the prompt)
      --root DIR      Firefox profile root (folder containing profiles.ini)
  -h, --help          Show this help

PROFILE_DIR as a bare argument is also accepted.
USAGE
}

PROFILE=""

while (( $# > 0 )); do
    case "$1" in
        -p|--profile) [[ -n "${2:-}" ]] || die "$1 needs a nonempty value"; PROFILE="$2"; shift 2 ;;
        --root)       [[ -n "${2:-}" ]] || die "$1 needs a nonempty value"; PROFILE_ROOT="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           die "Unknown option: $1 (see --help)" ;;
        *)            [[ -n "$1" ]] || die "Profile directory must not be empty"; PROFILE="$1"; shift ;;
    esac
done

echo "Firefox Floating URL Bar installer"
echo

if [[ -z "$PROFILE" ]]; then
    PROFILE_ROOT="$(find_profile_root)" || die "Could not find a Firefox profile folder. Use --root DIR or --profile DIR."
    echo "Profile folder: $PROFILE_ROOT"

    if [[ "$PROFILE_ROOT" == *"/snap/"* ]]; then
        warn "Snap Firefox keeps its install directory read-only, so fx-autoconfig usually can't be installed there."
    fi

    choose_profile "$PROFILE_ROOT"
fi

require_autoconfig_profile "$PROFILE"
PROFILE="$(cd -- "$PROFILE" && pwd -P)"
require_profile_destinations "$PROFILE"

RUNNING=0
if firefox_running; then
    RUNNING=1
    warn "Firefox is running. Close it and reopen after installing."
fi

mkdir -p "$PROFILE/chrome/JS" "$PROFILE/chrome/CSS"

echo
echo "Installing:"
copy_with_backup "$SCRIPT_DIR/JS/replace-new-tab.uc.js" "$PROFILE/chrome/JS/replace-new-tab.uc.js"
copy_with_backup "$SCRIPT_DIR/CSS/firefox-floating-urlbar.uc.css"    "$PROFILE/chrome/CSS/firefox-floating-urlbar.uc.css"

save_profile "$PROFILE"

echo
echo "Installation complete."
echo "  Profile: $PROFILE"
echo

if (( RUNNING == 0 )); then
    clear_startup_cache "$PROFILE" || echo "Startup cache not cleared automatically. Clear it in about:support if changes do not appear."
else
    echo "After closing Firefox, clear the startup cache (about:support > Clear startup cache) and reopen."
fi

cat <<NOTES

Notes:
  - Ctrl+T (Cmd+T on macOS) opens the centred URL bar and submits the result
    in a new tab. Ctrl+L still navigates in the current tab as normal. The +
    button and File > New Tab remain unchanged.
  - If you have other CSS that changes URL bar behaviour (floating/centred URL
    bar mods, theme packs), disable it so the two don't fight.
  - Switch the feature off without uninstalling: set uc.floatingurlbar.enabled to false.
  - If you ran an older version of this script, check that browser.urlbar.openintab
    in about:config is what you expect (reset it if you never set it).
  - To remove everything: ./uninstall.sh
NOTES

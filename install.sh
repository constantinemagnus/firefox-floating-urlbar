#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=autoconfig.sh
source "$SCRIPT_DIR/autoconfig.sh"

usage() {
    cat <<USAGE
Usage: ./install.sh [options] [PROFILE_DIR]

For regular Firefox on Linux and macOS. Windows users: run install.ps1.
Installs fx-autoconfig when missing; existing loaders are preserved.

Options:
  -p, --profile DIR   Install into this profile folder (skips the prompt)
      --root DIR      Firefox profile root (folder containing profiles.ini)
      --firefox-dir DIR  Firefox installation directory (macOS: Contents/Resources)
  -h, --help          Show this help

PROFILE_DIR as a bare argument is also accepted.
USAGE
}

PROFILE=""
FIREFOX_DIR=""

while (( $# > 0 )); do
    case "$1" in
        -p|--profile) [[ -n "${2:-}" ]] || die "$1 needs a nonempty value"; PROFILE="$2"; shift 2 ;;
        --root)       [[ -n "${2:-}" ]] || die "$1 needs a nonempty value"; PROFILE_ROOT="$2"; shift 2 ;;
        --firefox-dir) [[ -n "${2:-}" ]] || die "$1 needs a nonempty value"; FIREFOX_DIR="$2"; shift 2 ;;
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

[[ -d "$PROFILE" && -f "$PROFILE/prefs.js" ]] || die "Not an initialized Firefox profile: $PROFILE. Start Firefox once first."
PROFILE="$(cd -- "$PROFILE" && pwd -P)"

RUNNING=0
if firefox_running; then
    RUNNING=1
    warn "Firefox is running. Close it and reopen after installing."
fi

ensure_autoconfig "$PROFILE" "$FIREFOX_DIR"
require_autoconfig_profile "$PROFILE"

mkdir -p "$PROFILE/chrome/JS" "$PROFILE/chrome/CSS"

echo
echo "Installing:"
install_payloads "$SCRIPT_DIR" "$PROFILE"

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
  - Ctrl+T opens the centered URL bar and loads the result in a new tab.
    Ctrl+L opens the same bar in the current tab, and Ctrl+K opens centered
    search (Cmd on macOS). The + button and File > New Tab remain unchanged.
  - Enable optional compact mode by setting uc.floatingurlbar.compact to true
    in about:config (with expanded vertical tabs).
  - If you have other CSS that changes URL-bar behavior (floating/centered URL
    bar mods, theme packs), disable it so the two don't conflict.
  - Switch the feature off without uninstalling: set uc.floatingurlbar.enabled to false.
  - Remove the customization with ./uninstall.sh; it offers optional cleanup of fx-autoconfig installed by us.
NOTES

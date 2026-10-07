#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<USAGE
Usage: ./uninstall.sh [options] [PROFILE_DIR]

Options:
  -p, --profile DIR   Uninstall from this profile folder
      --root DIR      Firefox profile root (folder containing profiles.ini)
  -h, --help          Show this help

Removes the script and stylesheet from the profile. If you edited an installed
file, a timestamped backup is kept. Firefox's prefs.js is never modified.
USAGE
}

PROFILE=""

while (( $# > 0 )); do
    case "$1" in
        -p|--profile) [[ $# -ge 2 ]] || die "$1 needs a value"; PROFILE="$2"; shift 2 ;;
        --root)       [[ $# -ge 2 ]] || die "$1 needs a value"; PROFILE_ROOT="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           die "Unknown option: $1 (see --help)" ;;
        *)            PROFILE="$1"; shift ;;
    esac
done

if [[ -z "$PROFILE" ]]; then
    if saved="$(load_saved_profile)"; then
        PROFILE="$saved"
        echo "Using saved profile: $PROFILE"
    else
        PROFILE_ROOT="$(find_profile_root)" || die "Could not find a Firefox profile folder. Use --root DIR or --profile DIR."
        choose_profile "$PROFILE_ROOT"
    fi
fi

[[ -d "$PROFILE" ]] || die "Profile does not exist: $PROFILE"

RUNNING=0
if firefox_running; then
    RUNNING=1
    warn "Firefox is running. Close it and reopen after uninstalling."
fi

echo
echo "Removing files:"

remove_installed() {
    local installed="$1" original="$2"

    if [[ ! -f "$installed" ]]; then
        echo "  (not found) ${installed#"$PROFILE"/}"
        return
    fi

    # Only keep a backup if the installed file differs from this repo's copy,
    # i.e. it was edited locally.
    if [[ ! -f "$original" ]] || ! cmp -s "$installed" "$original"; then
        local backup="$installed.bak-$(date +%Y%m%d%H%M%S)"
        cp "$installed" "$backup"
        echo "  backed up locally modified file to $(basename "$backup")"
    fi

    rm -f "$installed"
    echo "  removed ${installed#"$PROFILE"/}"
}

remove_installed "$PROFILE/chrome/JS/replace-new-tab.uc.js" "$SCRIPT_DIR/JS/replace-new-tab.uc.js"
remove_installed "$PROFILE/chrome/CSS/zen-newtab.uc.css"    "$SCRIPT_DIR/CSS/zen-newtab.uc.css"

if (( RUNNING == 0 )); then
    echo
    clear_startup_cache "$PROFILE" || true
fi

rm -f "$SAVED_PROFILE_FILE"

cat <<'NOTES'

Uninstalled. Reopen Firefox; if the old behaviour persists, clear the startup
cache in about:support.

Optional cleanup in about:config:
  - Reset any uc.floatingurlbar.* preferences you created.
  - If you ran an older version of this script, check browser.urlbar.openintab.
    Reset it if you never set it yourself.
NOTES

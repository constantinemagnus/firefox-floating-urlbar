#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_ROOT="$HOME/.mozilla/firefox"

echo "Zen-style Firefox New Tab installer"
echo

if [[ ! -d "$PROFILE_ROOT" ]]; then
    echo "Firefox profile directory not found:"
    echo "  $PROFILE_ROOT"
    exit 1
fi

find_firefox_install() {
    local candidates=(
        "/usr/lib/firefox"
        "/usr/lib64/firefox"
        "/opt/firefox"
        "/usr/local/lib/firefox"
    )

    for dir in "${candidates[@]}"; do
        if [[ -f "$dir/config.js" && -x "$dir/firefox" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done

    return 1
}

FIREFOX_INSTALL=""

if FIREFOX_INSTALL="$(find_firefox_install)"; then
    echo "Detected Firefox installation:"
    echo "  $FIREFOX_INSTALL"
else
    echo "Could not automatically detect the Firefox installation."
    echo
    echo "This feature requires fx-autoconfig to already be installed."
    echo

    read -r -p "Firefox installation directory: " FIREFOX_INSTALL

    if [[ ! -f "$FIREFOX_INSTALL/config.js" ]]; then
        echo
        echo "config.js was not found in:"
        echo "  $FIREFOX_INSTALL"
        echo
        echo "Make sure fx-autoconfig is installed correctly."
        exit 1
    fi
fi

mapfile -t PROFILES < <(
    find "$PROFILE_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -exec test -f '{}/prefs.js' \; \
        -print | sort
)

if (( ${#PROFILES[@]} == 0 )); then
    echo "No Firefox profiles found."
    exit 1
fi

PROFILE=""

if [[ $# -ge 1 ]]; then
    PROFILE="$1"
else
    echo
    echo "Firefox profiles found:"
    echo

    for i in "${!PROFILES[@]}"; do
        printf '%d. %s\n' \
            "$((i + 1))" \
            "${PROFILES[$i]}"
    done

    echo
    read -r -p "Select profile [1-${#PROFILES[@]}]: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
       (( choice < 1 || choice > ${#PROFILES[@]} )); then
        echo "Invalid selection."
        exit 1
    fi

    PROFILE="${PROFILES[$((choice - 1))]}"
fi

if [[ ! -d "$PROFILE" ]]; then
    echo "Profile does not exist:"
    echo "  $PROFILE"
    exit 1
fi

if [[ ! -f "$PROFILE/chrome/utils/boot.sys.mjs" ]]; then
    echo
    echo "fx-autoconfig is not installed in this Firefox profile:"
    echo "  $PROFILE"
    echo
    echo "Install fx-autoconfig into this profile first."
    exit 1
fi

mkdir -p \
    "$PROFILE/chrome/JS" \
    "$PROFILE/chrome/CSS"

cp "$SCRIPT_DIR/JS/replace-new-tab.uc.js" \
   "$PROFILE/chrome/JS/replace-new-tab.uc.js"

cp "$SCRIPT_DIR/CSS/zen-newtab.uc.css" \
   "$PROFILE/chrome/CSS/zen-newtab.uc.css"

echo
echo "Installation complete."
echo
echo "Profile:"
echo "  $PROFILE"
echo
echo "Installed:"
echo "  chrome/JS/replace-new-tab.uc.js"
echo "  chrome/CSS/zen-newtab.uc.css"
echo
echo "Clear Firefox's startup cache in about:support and restart Firefox."

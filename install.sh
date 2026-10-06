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

mapfile -t PROFILES < <(
    find "$PROFILE_ROOT" -mindepth 1 -maxdepth 1 -type d \
        \( -name '*.default-release' -o -name '*.default-release-*' \) \
        -print | sort
)

if (( ${#PROFILES[@]} == 0 )); then
    echo "No Firefox default-release profiles found."
    echo
    echo "Run this script with an explicit profile path:"
    echo
    echo "  ./install.sh /path/to/firefox/profile"
    exit 1
fi

PROFILE=""

if [[ $# -ge 1 ]]; then
    PROFILE="$1"
else
    echo "Firefox profiles found:"
    echo

    for i in "${!PROFILES[@]}"; do
        printf '%d. %s\n' "$((i + 1))" "${PROFILES[$i]}"
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

if [[ ! -f /usr/lib/firefox/config.js ]]; then
    echo "fx-autoconfig does not appear to be installed."
    echo
    echo "Install fx-autoconfig first:"
    echo "  https://github.com/MrOtherGuy/fx-autoconfig"
    exit 1
fi

if [[ ! -f "$PROFILE/chrome/utils/boot.sys.mjs" ]]; then
    echo "fx-autoconfig is not installed in this profile:"
    echo "  $PROFILE"
    echo
    echo "Install the fx-autoconfig profile files first."
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
echo "Installed successfully."
echo
echo "Profile:"
echo "  $PROFILE"
echo
echo "Files:"
echo "  chrome/JS/replace-new-tab.uc.js"
echo "  chrome/CSS/zen-newtab.uc.css"
echo
echo "Clear Firefox's startup cache via about:support, then restart Firefox."

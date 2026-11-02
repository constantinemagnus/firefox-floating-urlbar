#!/usr/bin/env bash
# Sourced by install.sh and uninstall.sh after lib.sh.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fx-autoconfig.conf
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fx-autoconfig.conf"
AUTOCONFIG_MODULES=(boot.sys.mjs fs.sys.mjs utils.sys.mjs uc_api.sys.mjs module_loader.mjs)
AUTOCONFIG_FILES=(chrome.manifest "${AUTOCONFIG_MODULES[@]}" fx-autoconfig.LICENSE fx-autoconfig.txt)
# config.js comes first: config-prefs.js activates it.
STARTUP_FILES=(config.js defaults/pref/config-prefs.js)
# Our loader in chrome/utils: holds the installed fx-autoconfig commit.
PROFILE_MARKER=.floating-urlbar-source
# Our startup files in the Firefox directory.
SHARED_MARKER=.floating-urlbar-autoconfig

find_firefox_directory() {
    local profile="$1" explicit="$2" hint="" executable="" candidate
    if [[ -n "$explicit" ]]; then
        hint="$explicit"
    elif [[ -f "$profile/compatibility.ini" ]]; then
        hint="$(awk -F= '$1 == "LastPlatformDir" { sub(/\r$/, ""); print substr($0, 17); exit }' "$profile/compatibility.ini")"
    fi
    if [[ -z "$explicit" ]]; then
        executable="$(command -v firefox || true)"
        while [[ -L "$executable" ]]; do
            candidate="$(readlink "$executable")"
            if [[ "$candidate" == /* ]]; then executable="$candidate";
            else executable="$(dirname "$executable")/$candidate"; fi
        done
    fi
    local candidates=("$hint")
    if [[ -z "$explicit" ]]; then
        candidates+=("${executable%/*}" /usr/lib/firefox /usr/lib64/firefox /opt/firefox
            /Applications/Firefox.app/Contents/Resources
            "$HOME/Applications/Firefox.app/Contents/Resources")
    fi
    for candidate in "${candidates[@]}"; do
        [[ -d "$candidate" && -f "$candidate/application.ini" ]] || continue
        if [[ -x "$candidate/firefox" || -x "$candidate/firefox-bin" ||
              -x "$candidate/../MacOS/firefox" ]]; then
            (cd -- "$candidate" && pwd -P)
            return
        fi
    done
    die "Cannot find Firefox's installation directory. Pass --firefox-dir DIR (on macOS, Firefox.app/Contents/Resources)."
}

autoconfig_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }';
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{ print $1 }';
    else die "A SHA-256 tool is required (sha256sum or shasum)."; fi
}

packaged_autoconfig_directory() {
    [[ "$1" == /usr/lib/firefox && -f /usr/share/fx-autoconfig/utils/boot.sys.mjs ]] || return 1
    command -v pacman >/dev/null 2>&1 && pacman -Q fx-autoconfig >/dev/null 2>&1 || return 1
    printf '%s\n' /usr/share/fx-autoconfig/utils
}

# Runs a command in the Firefox directory, through sudo only when it is not writable.
as_firefox_owner() {
    local firefox_dir="$1" dir
    shift
    for dir in "$firefox_dir" "$firefox_dir/defaults" "$firefox_dir/defaults/pref"; do
        if [[ -d "$dir" && ! -w "$dir" ]]; then
            command -v sudo >/dev/null 2>&1 || die "Write access to $firefox_dir is required; sudo is not available."
            sudo "$@"
            return
        fi
    done
    "$@"
}

# Firefox reads only one AutoConfig file; LibreWolf and others ship their own.
check_foreign_autoconfig() {
    local file
    for file in "$1/defaults/pref/"*.js; do
        [[ -f "$file" && "${file##*/}" != config-prefs.js ]] || continue
        if grep -Eq 'general[.]config[.](filename|sandbox_enabled|obscure_value)' "$file"; then
            die "Another AutoConfig configuration exists: $file. It will not be overwritten."
        fi
    done
}

install_autoconfig_startup() {
    local source="$1" firefox_dir="$2" file dest needed=0 existing=0 owned=0
    check_foreign_autoconfig "$firefox_dir"
    [[ -f "$firefox_dir/$SHARED_MARKER" ]] && owned=1
    for file in "${STARTUP_FILES[@]}"; do
        dest="$firefox_dir/$file"
        if [[ ! -f "$dest" ]]; then
            needed=1
        else
            existing=1
            if ! cmp -s "$source/$file" "$dest"; then
                (( owned )) || die "Existing AutoConfig startup file was not installed by this project: $dest. Remove or merge it first."
                needed=1
            fi
        fi
    done
    (( needed )) || return 0
    echo "Setting up shared AutoConfig startup files in $firefox_dir for ALL profiles (config.js and defaults/pref/config-prefs.js; AutoConfig sandbox disabled)."
    as_firefox_owner "$firefox_dir" install -d -m755 "$firefox_dir/defaults/pref" || return 1
    for file in "${STARTUP_FILES[@]}"; do
        as_firefox_owner "$firefox_dir" install -m644 "$source/$file" "$firefox_dir/$file" || return 1
    done
    # Startup files we did not create stay unowned, so uninstall never removes them.
    if (( owned || ! existing )); then
        printf '%s\n' "${STARTUP_FILES[@]}" |
            as_firefox_owner "$firefox_dir" tee "$firefox_dir/$SHARED_MARKER" >/dev/null || return 1
    fi
}

autoconfig_current() {
    local utils="$1" firefox_dir="$2" file
    [[ -f "$utils/$PROFILE_MARKER" && "$(head -n1 "$utils/$PROFILE_MARKER")" == "$AUTOCONFIG_COMMIT" ]] || return 1
    for file in "${AUTOCONFIG_FILES[@]}"; do [[ -f "$utils/$file" ]] || return 1; done
    for file in "${STARTUP_FILES[@]}"; do [[ -f "$firefox_dir/$file" ]] || return 1; done
}

ensure_autoconfig() (
    set -e
    local profile="$1" firefox_dir="$2" utils="$1/chrome/utils" file source work
    if [[ -f "$utils/boot.sys.mjs" && -f "$utils/chrome.manifest" && ! -f "$utils/$PROFILE_MARKER" ]]; then
        echo "Using existing fx-autoconfig profile loader."
        return 0
    fi
    if [[ "$profile" == *"/.var/app/"* || "$profile" == *"/snap/firefox/"* ]]; then
        die "Automatic first-time AutoConfig setup supports regular Firefox installations. Flatpak/Snap need separate setup; existing loaders are supported."
    fi
    if [[ -d "$utils" && ! -f "$utils/$PROFILE_MARKER" && -n "$(ls -A "$utils")" ]]; then
        die "Existing incomplete loader in $utils; restore or move it aside before installing."
    fi
    firefox_dir="$(find_firefox_directory "$profile" "$firefox_dir")"
    autoconfig_current "$utils" "$firefox_dir" && return 0
    mkdir -p "$utils" "$profile/chrome/resources"

    if source="$(packaged_autoconfig_directory "$firefox_dir")"; then
        [[ -f "$firefox_dir/config.js" && -f "$firefox_dir/defaults/pref/config-prefs.js" ]] ||
            die "Pacman-managed fx-autoconfig is missing its startup files in $firefox_dir. Reinstall the fx-autoconfig package."
        echo "Using pacman-managed fx-autoconfig modules."
        cp -- "$source/chrome.manifest" "$utils/chrome.manifest"
        for file in "${AUTOCONFIG_MODULES[@]}"; do ln -sfn -- "$source/$file" "$utils/$file"; done
        # Package upgrades update the links; the profile now has an external loader.
        rm -f -- "$utils/$PROFILE_MARKER"
        echo "fx-autoconfig is ready."
        return 0
    fi

    command -v curl >/dev/null 2>&1 || die "curl is required to download fx-autoconfig."
    work="$(mktemp -d)"
    trap 'rm -rf -- "$work"' EXIT
    echo "Downloading verified fx-autoconfig snapshot..."
    curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 \
        "https://codeload.github.com/MrOtherGuy/fx-autoconfig/tar.gz/$AUTOCONFIG_COMMIT" \
        --output "$work/source.tar.gz" || die "Could not download fx-autoconfig; nothing was installed."
    [[ "$(autoconfig_sha256 "$work/source.tar.gz")" == "$AUTOCONFIG_TAR_SHA256" ]] ||
        die "fx-autoconfig checksum mismatch; nothing was installed."
    tar -xzf "$work/source.tar.gz" -C "$work" || die "Could not extract fx-autoconfig."
    source="$work/fx-autoconfig-$AUTOCONFIG_COMMIT"
    for file in LICENSE program/config.js program/defaults/pref/config-prefs.js \
        profile/chrome/utils/chrome.manifest "${AUTOCONFIG_MODULES[@]/#/profile/chrome/utils/}"; do
        [[ -f "$source/$file" ]] || die "fx-autoconfig source is incomplete: $file"
    done

    install_autoconfig_startup "$source/program" "$firefox_dir"
    # The marker goes first, so an interrupted copy is still recognized as ours.
    printf 'pending\n' > "$utils/$PROFILE_MARKER"
    for file in chrome.manifest "${AUTOCONFIG_MODULES[@]}"; do
        cp -- "$source/profile/chrome/utils/$file" "$utils/$file"
    done
    cp -- "$source/LICENSE" "$utils/fx-autoconfig.LICENSE"
    printf 'fx-autoconfig by MrOtherGuy\nLicense: MPL-2.0 (see fx-autoconfig.LICENSE).\nUnmodified source: https://github.com/MrOtherGuy/fx-autoconfig/tree/%s\n' \
        "$AUTOCONFIG_COMMIT" > "$utils/fx-autoconfig.txt"
    printf '%s\n' "$AUTOCONFIG_COMMIT" > "$utils/$PROFILE_MARKER"
    echo "fx-autoconfig is ready."
)

remove_autoconfig() {
    local profile="$1" firefox_dir="$2" shared="$3" utils="$1/chrome/utils" file other=""
    # Other scripts and styles may depend on this loader, even after our two files go.
    if [[ -d "$profile/chrome" ]]; then
        other="$(find "$profile/chrome" -path "$utils" -prune -o -type f \
            \( -iname '*.js' -o -iname '*.mjs' -o -iname '*.css' \) \
            ! -path "$profile/chrome/userChrome.css" ! -path "$profile/chrome/userContent.css" -print)"
    fi
    [[ -z "$other" ]] || die "Other customization found; keeping fx-autoconfig: $other"
    if (( shared )); then
        firefox_dir="$(find_firefox_directory "$profile" "$firefox_dir")"
        if [[ -f "$firefox_dir/$SHARED_MARKER" ]]; then
            # Disable AutoConfig before removing its script. This affects all profiles.
            as_firefox_owner "$firefox_dir" rm -f -- "$firefox_dir/defaults/pref/config-prefs.js" \
                "$firefox_dir/config.js" "$firefox_dir/$SHARED_MARKER" || return 1
            echo "Removed shared AutoConfig startup files from $firefox_dir."
        else
            echo "Shared AutoConfig startup files in $firefox_dir were not installed by us; keeping them."
        fi
    fi
    if [[ -f "$utils/$PROFILE_MARKER" ]]; then
        # .floating-urlbar-files is the hash receipt written by older versions.
        for file in "${AUTOCONFIG_FILES[@]}" "$PROFILE_MARKER" .floating-urlbar-files; do
            rm -f -- "${utils:?}/$file" || return 1
        done
        rmdir "$utils" 2>/dev/null || true
        echo "Removed our fx-autoconfig profile loader."
    else
        echo "The fx-autoconfig profile loader was not installed by us; keeping it."
    fi
    if (( shared == 0 )); then echo "Shared Firefox startup files remain; --remove-shared-autoconfig also removes files we created for all profiles."; fi
}

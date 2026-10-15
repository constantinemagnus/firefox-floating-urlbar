#!/usr/bin/env bash
# Sourced by install.sh after lib.sh.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fx-autoconfig.conf
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fx-autoconfig.conf"

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

require_packaged_autoconfig_startup() {
    [[ -f "$1/config.js" && -f "$1/defaults/pref/config-prefs.js" ]] ||
        die "Pacman-managed fx-autoconfig is missing its startup files in $1. Reinstall the fx-autoconfig package."
}

check_autoconfig_startup() {
    local source="$1" firefox_dir="$2" dir file dest
    for dir in "$firefox_dir/defaults" "$firefox_dir/defaults/pref"; do
        require_directory_destination "$dir"
    done
    for file in config.js defaults/pref/config-prefs.js; do
        dest="$firefox_dir/$file"
        require_file_destination "$dest"
        if [[ -f "$dest" ]] && ! cmp -s "$source/$file" "$dest"; then
            die "Existing AutoConfig file differs: $dest. Keep your configuration and install fx-autoconfig into it manually."
        fi
    done
    for file in "$firefox_dir/defaults/pref/"*.js; do
        [[ -f "$file" && "$file" != "$firefox_dir/defaults/pref/config-prefs.js" ]] || continue
        if grep -Eq 'general[.]config[.](filename|sandbox_enabled|obscure_value)' "$file"; then
            die "Another AutoConfig configuration exists: $file. It will not be overwritten."
        fi
    done
}

install_autoconfig_startup() {
    local source="$1" firefox_dir="$2" dir file needed=0
    local elevate=()
    check_autoconfig_startup "$source" "$firefox_dir"
    for file in config.js defaults/pref/config-prefs.js; do
        [[ -f "$firefox_dir/$file" ]] || needed=1
    done
    (( needed )) || return 0
    echo "Setting up AutoConfig in $firefox_dir (config.js and defaults/pref/config-prefs.js; AutoConfig sandbox disabled)."
    for dir in "$firefox_dir" "$firefox_dir/defaults" "$firefox_dir/defaults/pref"; do
        if [[ -d "$dir" && ! -w "$dir" ]]; then
            command -v sudo >/dev/null 2>&1 || die "Write access to $firefox_dir is required; sudo is not available."
            elevate=(sudo)
            break
        fi
    done
    # Activate AutoConfig only after config.js is in place.
    "${elevate[@]+"${elevate[@]}"}" install -d -m755 "$firefox_dir/defaults/pref" || return 1
    for file in config.js defaults/pref/config-prefs.js; do
        if [[ ! -f "$firefox_dir/$file" ]]; then
            "${elevate[@]+"${elevate[@]}"}" install -m644 "$source/$file" "$firefox_dir/$file" || return 1
        fi
    done
}

ensure_autoconfig() (
    set -e
    local profile="$1" firefox_dir="$2" utils="$1/chrome/utils"
    local marker="$utils/.floating-urlbar-source" file source download_dir="" link_dir="" packaged=0 complete=1 repair_only=0
    local modules=(boot.sys.mjs fs.sys.mjs utils.sys.mjs uc_api.sys.mjs module_loader.mjs)
    # Package-backed profiles also need startup validation when reusing their loader.
    if [[ -L "$utils/boot.sys.mjs" && "$(readlink "$utils/boot.sys.mjs")" == /usr/share/fx-autoconfig/utils/boot.sys.mjs ]]; then
        firefox_dir="$(find_firefox_directory "$profile" "$firefox_dir")"
        require_packaged_autoconfig_startup "$firefox_dir"
    fi
    if [[ -f "$utils/boot.sys.mjs" && -f "$utils/chrome.manifest" && ! -e "$marker" && ! -L "$marker" ]]; then
        if [[ "$profile" != *"/.var/app/"* && "$profile" != *"/snap/firefox/"* ]]; then
            if firefox_dir="$(find_firefox_directory "$profile" "$firefox_dir" 2>/dev/null)"; then
                if [[ ! -f "$firefox_dir/config.js" || ! -f "$firefox_dir/defaults/pref/config-prefs.js" ]]; then
                    warn "Existing profile loader found, but standard AutoConfig startup files are missing in $firefox_dir. Restore your loader's startup configuration if it does not load; custom configurations are left unchanged."
                fi
            else
                warn "Existing profile loader found, but Firefox's startup configuration could not be checked. Restore it if the loader does not load."
            fi
        fi
        echo "Using existing fx-autoconfig profile loader."
        return 0
    fi
    require_directory_destination "$utils"
    require_directory_destination "$profile/chrome/resources"
    require_file_destination "$marker"
    for file in chrome.manifest "${modules[@]}"; do
        [[ -f "$utils/$file" ]] || complete=0
    done
    if [[ -f "$marker" && "$(cat "$marker")" == "$AUTOCONFIG_COMMIT" && "$complete" == 1 ]]; then
        firefox_dir="$(find_firefox_directory "$profile" "$firefox_dir")"
        if [[ -f "$firefox_dir/config.js" && -f "$firefox_dir/defaults/pref/config-prefs.js" &&
              -f "$utils/fx-autoconfig.LICENSE" && -f "$utils/fx-autoconfig.txt" ]]; then
            return 0
        fi
        repair_only=1
    fi
    if [[ "$profile" == *"/.var/app/"* || "$profile" == *"/snap/firefox/"* ]]; then
        die "Automatic first-time AutoConfig setup supports regular Firefox installations. Flatpak/Snap need separate setup; existing loaders are supported."
    fi
    if [[ -d "$utils" && ! -f "$marker" ]]; then
        for file in "$utils/"* "$utils/".[!.]* "$utils/"..?*; do
            [[ ! -e "$file" && ! -L "$file" ]] || die "Existing incomplete loader in $utils; restore or move it aside before installing."
        done
    fi
    firefox_dir="$(find_firefox_directory "$profile" "$firefox_dir")"
    if source="$(packaged_autoconfig_directory "$firefox_dir")"; then
        packaged=1
        require_packaged_autoconfig_startup "$firefox_dir"
        echo "Using pacman-managed fx-autoconfig modules."
    else
        command -v curl >/dev/null 2>&1 || die "curl is required to download fx-autoconfig."
        download_dir="$(mktemp -d)"
        trap 'rm -rf -- "$download_dir"' EXIT
        echo "Downloading verified fx-autoconfig snapshot..."
        curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 \
            "https://codeload.github.com/MrOtherGuy/fx-autoconfig/tar.gz/$AUTOCONFIG_COMMIT" \
            --output "$download_dir/source.tar.gz" || die "Could not download fx-autoconfig; nothing was installed."
        [[ "$(autoconfig_sha256 "$download_dir/source.tar.gz")" == "$AUTOCONFIG_TAR_SHA256" ]] ||
            die "fx-autoconfig checksum mismatch; nothing was installed."
        tar -xzf "$download_dir/source.tar.gz" -C "$download_dir" || die "Could not extract fx-autoconfig."
        source="$download_dir/fx-autoconfig-$AUTOCONFIG_COMMIT/profile/chrome/utils"
    fi
    for file in chrome.manifest "${modules[@]}"; do
        [[ -f "$source/$file" ]] || die "fx-autoconfig source is incomplete: $file"
        require_file_destination "$utils/$file"
    done
    if (( packaged == 0 )); then
        [[ -f "$download_dir/fx-autoconfig-$AUTOCONFIG_COMMIT/LICENSE" ]] || die "fx-autoconfig source is missing its license."
        require_file_destination "$utils/fx-autoconfig.LICENSE"
        require_file_destination "$utils/fx-autoconfig.txt"
        install_autoconfig_startup "$download_dir/fx-autoconfig-$AUTOCONFIG_COMMIT/program" "$firefox_dir" || return 1
    fi
    mkdir -p "$utils" || return 1
    # An interrupted install must remain distinguishable from an external loader.
    if (( repair_only == 0 )); then printf 'pending\n' > "$marker" || return 1; fi
    if (( packaged == 0 )); then
        copy_with_backup "$download_dir/fx-autoconfig-$AUTOCONFIG_COMMIT/LICENSE" "$utils/fx-autoconfig.LICENSE" || return 1
        printf 'fx-autoconfig by MrOtherGuy\nLicense: MPL-2.0 (see fx-autoconfig.LICENSE).\nUnmodified source: https://github.com/MrOtherGuy/fx-autoconfig/tree/%s\n' \
            "$AUTOCONFIG_COMMIT" > "$download_dir/fx-autoconfig.txt" || return 1
        copy_with_backup "$download_dir/fx-autoconfig.txt" "$utils/fx-autoconfig.txt" || return 1
    fi
    if (( repair_only )); then
        echo "fx-autoconfig setup repaired."
        return 0
    fi
    mkdir -p "$utils" "$profile/chrome/JS" "$profile/chrome/CSS" "$profile/chrome/resources"
    if (( packaged )); then
        link_dir="$(mktemp -d "$utils/.floating-urlbar-links.XXXXXX")" || return 1
        trap 'rm -rf -- "$link_dir"' EXIT
    fi
    copy_with_backup "$source/chrome.manifest" "$utils/chrome.manifest" || return 1
    for file in "${modules[@]}"; do
        if (( packaged )); then
            if [[ -f "$utils/$file" ]]; then
                backup_file "$utils/$file" >/dev/null || return 1
            fi
            ln -s "$source/$file" "$link_dir/$file" || return 1
            mv -f -- "$link_dir/$file" "$utils/$file" || return 1
        else copy_with_backup "$source/$file" "$utils/$file" || return 1; fi
    done
    if (( packaged == 0 )); then printf '%s\n' "$AUTOCONFIG_COMMIT" > "$marker";
    else rm -f "$marker"; fi
    echo "fx-autoconfig is ready."
)

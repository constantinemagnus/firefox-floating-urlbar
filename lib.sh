#!/usr/bin/env bash
# Shared helpers for install.sh, update.sh and uninstall.sh.
# Source this file; don't run it directly.

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/firefox-floating-urlbar"
SAVED_PROFILE_FILE="$CONFIG_DIR/profile"

die()  { echo "Error: $*" >&2; exit 1; }
warn() { echo "Warning: $*" >&2; }

# ---------------------------------------------------------------
# Locating Firefox
# ---------------------------------------------------------------

# Prints the Firefox profile root (the folder containing profiles.ini).
# Override with PROFILE_ROOT=/path or --root /path.
find_profile_root() {
    if [[ -n "${PROFILE_ROOT:-}" ]]; then
        [[ -d "$PROFILE_ROOT" ]] || die "Profile root does not exist: $PROFILE_ROOT"
        printf '%s\n' "$PROFILE_ROOT"
        return 0
    fi

    local candidates=(
        "$HOME/.mozilla/firefox"
        "$HOME/.config/mozilla/firefox"
        "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
        "$HOME/snap/firefox/common/.mozilla/firefox"
        "$HOME/Library/Application Support/Firefox"
    )

    local dir
    for dir in "${candidates[@]}"; do
        if [[ -f "$dir/profiles.ini" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done

    return 1
}

firefox_running() {
    pgrep -x firefox >/dev/null 2>&1 ||
    pgrep -x firefox-bin >/dev/null 2>&1 ||
    pgrep -x Firefox >/dev/null 2>&1
}

# ---------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------

# Prints "name|absolute-path|raw-path" for each profile in profiles.ini.
list_profiles_from_ini() {
    local root="$1"
    local ini="$root/profiles.ini"

    [[ -f "$ini" ]] || return 0

    awk -F= -v root="$root" '
        function flush() {
            if (path != "") {
                full = (rel == "0") ? path : root "/" path
                print name "|" full "|" path
            }
            name = ""; path = ""; rel = "1"
        }
        BEGIN { rel = "1" }
        /^\[Profile[0-9]+\]/ { flush(); inprof = 1; next }
        /^\[/                { flush(); inprof = 0; next }
        inprof && $1 == "Name"       { name = substr($0, index($0, "=") + 1) }
        inprof && $1 == "Path"       { path = substr($0, index($0, "=") + 1) }
        inprof && $1 == "IsRelative" { rel  = $2 }
        END { flush() }
    ' "$ini" | tr -d '\r'
}

# Prints the raw Path of the profile Firefox treats as default, if known.
default_profile_raw() {
    local root="$1" value=""

    if [[ -f "$root/installs.ini" ]]; then
        value="$(awk -F= '$1 == "Default" { print substr($0, 9); exit }' "$root/installs.ini" | tr -d '\r')"
    fi

    if [[ -z "$value" && -f "$root/profiles.ini" ]]; then
        value="$(awk '
            /^\[Install/ { s = 1; next }
            /^\[/        { s = 0 }
            s && /^Default=/ { print substr($0, 9); exit }
        ' "$root/profiles.ini" | tr -d '\r')"
    fi

    printf '%s\n' "$value"
}

# Sets the global PROFILE. Prompts if more than one candidate.
choose_profile() {
    local root="$1"
    local names=() paths=() raws=()
    local line name path raw

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line%%|*}"
        line="${line#*|}"
        path="${line%%|*}"
        raw="${line#*|}"
        [[ -f "$path/prefs.js" ]] || continue   # skip profiles that were never used
        names+=("$name"); paths+=("$path"); raws+=("$raw")
    done < <(list_profiles_from_ini "$root")

    # Fallback: profiles.ini missing or empty. Look for folders with prefs.js.
    if (( ${#paths[@]} == 0 )); then
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            names+=("$(basename "$path")"); paths+=("$path"); raws+=("")
        done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/prefs.js' \; -print | sort)
    fi

    (( ${#paths[@]} > 0 )) || die "No Firefox profiles found in $root"

    local default_raw default_idx=-1 i
    default_raw="$(default_profile_raw "$root")"

    if [[ -n "$default_raw" ]]; then
        for i in "${!raws[@]}"; do
            if [[ "${raws[$i]}" == "$default_raw" ]]; then
                default_idx="$i"
                break
            fi
        done
    fi

    if (( ${#paths[@]} == 1 )); then
        PROFILE="${paths[0]}"
        echo "Using the only profile found: ${names[0]}"
        return 0
    fi

    echo
    echo "Firefox profiles:"
    echo
    for i in "${!paths[@]}"; do
        printf '  %d. %s  (%s)%s\n' \
            "$((i + 1))" "${names[$i]}" "${paths[$i]}" \
            "$([[ $i -eq $default_idx ]] && echo '  [default]')"
    done
    echo

    local prompt choice
    if (( default_idx >= 0 )); then
        prompt="Select profile [1-${#paths[@]}, Enter = $((default_idx + 1))]: "
    else
        prompt="Select profile [1-${#paths[@]}]: "
    fi

    read -r -p "$prompt" choice

    if [[ -z "$choice" && $default_idx -ge 0 ]]; then
        choice="$((default_idx + 1))"
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#paths[@]} )); then
        die "Invalid selection."
    fi

    PROFILE="${paths[$((choice - 1))]}"
}

# This project assumes fx-autoconfig is already installed in the profile.
# boot.sys.mjs and chrome.manifest are the loader's core; if they're missing
# nothing will load, so that's fatal. The other loader files differ between
# fx-autoconfig versions (e.g. fs.jsm vs fs.sys.mjs), so those only warn.
require_autoconfig_profile() {
    local profile="$1"
    local utils="$profile/chrome/utils"

    [[ -d "$profile" ]] || die "Profile does not exist: $profile"

    local missing=()
    local file
    for file in boot.sys.mjs chrome.manifest; do
        [[ -f "$utils/$file" ]] || missing+=("$file")
    done

    if (( ${#missing[@]} > 0 )); then
        echo >&2
        echo "fx-autoconfig is missing or incomplete in this profile:" >&2
        echo "  $profile" >&2
        echo >&2
        echo "Missing in chrome/utils:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        echo >&2
        echo "Install fx-autoconfig first:" >&2
        echo "  https://github.com/MrOtherGuy/fx-autoconfig" >&2
        exit 1
    fi

    [[ -f "$utils/utils.sys.mjs" ]] ||
        warn "chrome/utils/utils.sys.mjs not found; your fx-autoconfig install may be incomplete."

    if [[ ! -f "$utils/fs.sys.mjs" && ! -f "$utils/fs.jsm" ]]; then
        warn "chrome/utils/fs.sys.mjs (or fs.jsm) not found; your fx-autoconfig install may be incomplete."
    fi
}

save_profile() {
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' "$1" > "$SAVED_PROFILE_FILE"
}

load_saved_profile() {
    [[ -f "$SAVED_PROFILE_FILE" ]] || return 1
    local saved
    saved="$(head -n1 "$SAVED_PROFILE_FILE")"
    [[ -n "$saved" && -d "$saved" ]] || return 1
    printf '%s\n' "$saved"
}

# ---------------------------------------------------------------
# File helpers
# ---------------------------------------------------------------

# Copies src to dest; if dest exists and differs, keeps a timestamped backup.
copy_with_backup() {
    local src="$1" dest="$2"

    if [[ -f "$dest" ]] && ! cmp -s "$src" "$dest"; then
        local backup="$dest.bak-$(date +%Y%m%d%H%M%S)"
        cp "$dest" "$backup"
        echo "  Backed up existing file to: $(basename "$backup")"
    fi

    cp "$src" "$dest"
    echo "  installed $(basename "$dest")"
}

# Best-effort only: removes the startup cache at the usual locations. The cache
# lives in the profile's local-data folder, which varies by install type, so
# about:support > "Clear startup cache" is still the reliable method.
# Only call while Firefox is closed.
clear_startup_cache() {
    local profile_name
    profile_name="$(basename "$1")"

    local candidates=(
        "$HOME/.cache/mozilla/firefox/$profile_name/startupCache"
        "$HOME/.var/app/org.mozilla.firefox/cache/mozilla/firefox/$profile_name/startupCache"
        "$HOME/Library/Caches/Firefox/Profiles/$profile_name/startupCache"
    )

    local dir cleared=1
    for dir in "${candidates[@]}"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            echo "Cleared startup cache: $dir"
            cleared=0
        fi
    done

    return "$cleared"
}

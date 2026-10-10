#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
export XDG_CONFIG_HOME="$TEST_DIR/config"
# shellcheck source=../lib.sh
source "$REPO_DIR/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Save paths from the install caller's directory, then load from elsewhere.
mkdir -p "$TEST_DIR/caller/profile"
(cd "$TEST_DIR/caller"; save_profile profile)
[[ "$(load_saved_profile)" == "$TEST_DIR/caller/profile" ]] || fail "relative profile persistence"
printf 'profile\n' > "$SAVED_PROFILE_FILE"
if (cd "$TEST_DIR/caller"; load_saved_profile); then fail "ambiguous legacy relative path accepted"; fi

# Normalize CRLF before comparing IsRelative, including paths with spaces.
mkdir -p "$TEST_DIR/ini" "$TEST_DIR/absolute profile"
printf '[Profile0]\r\nName=Test\r\nIsRelative=0\r\nPath=%s\r\n' "$TEST_DIR/absolute profile" > "$TEST_DIR/ini/profiles.ini"
[[ "$(list_profiles_from_ini "$TEST_DIR/ini")" == "Test|$TEST_DIR/absolute profile|$TEST_DIR/absolute profile" ]] || fail "absolute CRLF profile"
printf '[Profile0]\r\nName=Test\r\nIsRelative=1\r\nPath=relative\r\n' > "$TEST_DIR/ini/profiles.ini"
[[ "$(list_profiles_from_ini "$TEST_DIR/ini")" == "Test|$TEST_DIR/ini/relative|relative" ]] || fail "relative CRLF profile"

# Both writes deliberately share a timestamp; neither backup may be lost.
date() { printf '20261009000000\n'; }
printf 'original' > "$TEST_DIR/destination"
printf 'one' > "$TEST_DIR/source"
copy_with_backup "$TEST_DIR/source" "$TEST_DIR/destination" >/dev/null
printf 'two' > "$TEST_DIR/source"
copy_with_backup "$TEST_DIR/source" "$TEST_DIR/destination" >/dev/null
backups=("$TEST_DIR"/destination.bak-20261009000000.*)
[[ ${#backups[@]} == 2 ]] || fail "backup collision"
contents="$(cat "${backups[@]}")"
[[ "$contents" == originalone || "$contents" == oneoriginal ]] || fail "backup contents lost"
unset -f date

# Synthetic profiles and a fake running process prevent real cache removal.
mkdir -p "$TEST_DIR/bin"
printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/bin/pgrep"
chmod +x "$TEST_DIR/bin/pgrep"
export PATH="$TEST_DIR/bin:$PATH"
PROFILE_A="$TEST_DIR/root-a/profile-a"
PROFILE_B="$TEST_DIR/root-b/profile-b"
for profile in "$PROFILE_A" "$PROFILE_B"; do
    mkdir -p "$profile/chrome/JS" "$profile/chrome/CSS" "$profile/chrome/utils"
    touch "$profile/prefs.js"
    for file in boot.sys.mjs chrome.manifest utils.sys.mjs fs.sys.mjs; do touch "$profile/chrome/utils/$file"; done
    cp "$REPO_DIR/JS/replace-new-tab.uc.js" "$profile/chrome/JS/"
    cp "$REPO_DIR/CSS/firefox-floating-urlbar.uc.css" "$profile/chrome/CSS/"
done
save_profile "$PROFILE_A"
bash "$REPO_DIR/uninstall.sh" --root "$TEST_DIR/root-b" > "$TEST_DIR/uninstall.log" 2>&1
[[ -f "$PROFILE_A/chrome/JS/replace-new-tab.uc.js" ]] || fail "uninstalled saved profile despite explicit root"
[[ ! -f "$PROFILE_B/chrome/JS/replace-new-tab.uc.js" ]] || fail "explicit uninstall root ignored"
(cd "$TEST_DIR/root-b"; bash "$REPO_DIR/install.sh" --profile profile-b > "$TEST_DIR/install.log" 2>&1)
[[ "$(load_saved_profile)" == "$PROFILE_B" ]] || fail "installer did not save absolute path"

# Exercise update.sh with an isolated Git stand-in: upstream advances from
# bbbbb to ccccc on a second lookup, and any pull/fetch-after-preview fails.
mkdir -p "$TEST_DIR/updater"
cp "$REPO_DIR/update.sh" "$REPO_DIR/lib.sh" "$TEST_DIR/updater/"
cat > "$TEST_DIR/updater/install.sh" <<'INSTALL'
#!/usr/bin/env bash
printf '%s\n' "$PWD" "$@" > "$TEST_INSTALL_TRACE"
INSTALL
chmod +x "$TEST_DIR/updater/install.sh"
cat > "$TEST_DIR/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_GIT_TRACE"
case "$1" in
    status) ;;
    fetch) [[ ! -e "$TEST_UPSTREAM_QUERIED" ]] ;;
    rev-parse)
        case "$2" in
            --abbrev-ref) printf 'origin/main\n' ;;
            HEAD) printf 'aaaaa\n' ;;
            '@{u}')
                if [[ -e "$TEST_UPSTREAM_QUERIED" ]]; then printf 'ccccc\n';
                else touch "$TEST_UPSTREAM_QUERIED"; printf 'bbbbb\n'; fi ;;
            *) exit 1 ;;
        esac ;;
    --no-pager) ;;
    merge) [[ "$*" == 'merge --ff-only bbbbb' ]] ;;
    *) exit 1 ;;
esac
GIT
chmod +x "$TEST_DIR/bin/git"
export TEST_GIT_TRACE="$TEST_DIR/git.trace"
export TEST_INSTALL_TRACE="$TEST_DIR/install.trace"
export TEST_UPSTREAM_QUERIED="$TEST_DIR/upstream-queried"

check_update() {
    rm -f -- "$TEST_GIT_TRACE" "$TEST_INSTALL_TRACE" "$TEST_UPSTREAM_QUERIED"
    (cd "$TEST_DIR/caller"; bash "$TEST_DIR/updater/update.sh" --yes "$@" > "$TEST_DIR/update.log" 2>&1)
    [[ "$(sed -n '1p' "$TEST_INSTALL_TRACE")" == "$TEST_DIR/caller" ]] || fail "update changed relative path base"
    [[ "$(awk '/^fetch / { n++ } END { print n+0 }' "$TEST_GIT_TRACE")" == 1 ]] || fail "update fetched twice"
    [[ "$(awk '/^merge --ff-only bbbbb$/ { n++ } END { print n+0 }' "$TEST_GIT_TRACE")" == 1 ]] || fail "update did not pin reviewed revision"
    [[ "$(awk '/^rev-parse @\{u\}$/ { n++ } END { print n+0 }' "$TEST_GIT_TRACE")" == 1 ]] || fail "update reread moving upstream"
}

save_profile "$PROFILE_A"
check_update --root "$TEST_DIR/root-b"
[[ "$(sed -n '2,3p' "$TEST_INSTALL_TRACE")" == "$(printf '%s\n' --root "$TEST_DIR/root-b")" ]] || fail "update root overridden by saved profile"
check_update --profile profile
[[ "$(sed -n '2,3p' "$TEST_INSTALL_TRACE")" == "$(printf '%s\n' --profile profile)" ]] || fail "explicit relative profile changed"
check_update profile
[[ "$(sed -n '2p' "$TEST_INSTALL_TRACE")" == profile ]] || fail "positional profile overridden"
check_update
[[ "$(sed -n '2,3p' "$TEST_INSTALL_TRACE")" == "$(printf '%s\n' --profile "$PROFILE_A")" ]] || fail "default saved profile not reused"
check_update --choose
[[ "$(wc -l < "$TEST_INSTALL_TRACE")" == 1 ]] || fail "choose reused saved profile"
export PROFILE_ROOT="$TEST_DIR/root-b"
check_update
[[ "$(wc -l < "$TEST_INSTALL_TRACE")" == 1 ]] || fail "environment root overridden"

echo "Shell regressions passed (temporary profiles and mocked Git; no real profile or repository updated)."

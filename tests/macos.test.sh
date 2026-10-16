#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    echo 'SKIP: macOS filesystem tests require a native macOS runner.'
    exit 0
fi

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
TEST_DIR="$(cd -- "$TEST_DIR" && pwd -P)"
trap 'test_status=$?; if (( test_status )); then tail -n 40 "$TEST_DIR"/*.log 2>/dev/null || true; fi; rm -rf -- "$TEST_DIR"; exit "$test_status"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export XDG_CONFIG_HOME="$TEST_DIR/config"
export PROFILE_ROOT="$TEST_DIR/Library/Application Support/Firefox"
source "$REPO_DIR/lib.sh"
source "$REPO_DIR/autoconfig.sh"

first="$PROFILE_ROOT/Profiles/profile [é] with spaces"
second="$TEST_DIR/second profile"
resources="$TEST_DIR/Firefox.app/Contents/Resources"
mkdir -p "$resources/defaults/pref" "$resources/../MacOS" "$TEST_DIR/bin"
printf '[App]\n' > "$resources/application.ini"
printf '#!/bin/sh\nexit 0\n' > "$resources/../MacOS/firefox"
chmod +x "$resources/../MacOS/firefox"
printf '// existing startup\n' > "$resources/config.js"
printf '// existing startup preferences\n' > "$resources/defaults/pref/config-prefs.js"
for profile in "$first" "$second"; do
    mkdir -p "$profile/chrome/utils"
    printf 'preserve preferences\n' > "$profile/prefs.js"
    for file in boot.sys.mjs chrome.manifest utils.sys.mjs fs.sys.mjs; do
        printf 'preserve loader\n' > "$profile/chrome/utils/$file"
    done
    printf '[Compatibility]\r\nLastPlatformDir=%s\r\n' "$resources" > "$profile/compatibility.ini"
done
printf '[Profile0]\r\nName=Relative\r\nIsRelative=1\r\nPath=Profiles/profile [é] with spaces\r\n[Profile1]\r\nName=Absolute\r\nIsRelative=0\r\nPath=%s\r\n[Profile2]\r\nName=Unused\r\nPath=unused\r\n' \
    "$second" > "$PROFILE_ROOT/profiles.ini"
printf '[InstallFixture]\r\nDefault=Profiles/profile [é] with spaces\r\n' > "$PROFILE_ROOT/installs.ini"

[[ "$(find_profile_root)" == "$PROFILE_ROOT" ]] || fail 'profile-root override not discovered'
[[ "$(find_firefox_directory "$first" '')" == "$resources" ]] || fail 'compatibility.ini did not find app resources'
choose_profile "$PROFILE_ROOT" <<< '' > "$TEST_DIR/choice.log"
[[ "$PROFILE" -ef "$first" ]] || fail 'relative profile/default selection failed'
choose_profile "$PROFILE_ROOT" <<< '2' > "$TEST_DIR/choice.log"
[[ "$PROFILE" -ef "$second" ]] || fail 'absolute profile selection failed'

# Keep process/cache decisions deterministic, without launching Firefox or sudo.
printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/bin/pgrep"
printf '#!/bin/sh\necho "unexpected network or elevation" >&2\nexit 1\n' > "$TEST_DIR/bin/curl"
cp "$TEST_DIR/bin/curl" "$TEST_DIR/bin/sudo"
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"
bash "$REPO_DIR/install.sh" --firefox-dir "$resources" <<< '' > "$TEST_DIR/install.log" 2>&1
cmp -s "$REPO_DIR/JS/replace-new-tab.uc.js" "$first/chrome/JS/replace-new-tab.uc.js" || fail 'default-profile install failed'
bash "$REPO_DIR/install.sh" --profile "$second" --firefox-dir "$resources" > "$TEST_DIR/install.log" 2>&1
save_profile "$first"
bash "$REPO_DIR/uninstall.sh" --root "$PROFILE_ROOT" <<< '2' > "$TEST_DIR/uninstall.log" 2>&1
[[ ! -e "$second/chrome/JS/replace-new-tab.uc.js" && ! -e "$second/chrome/CSS/firefox-floating-urlbar.uc.css" ]] || fail 'selected profile not uninstalled'
[[ -f "$first/chrome/JS/replace-new-tab.uc.js" && -f "$first/chrome/CSS/firefox-floating-urlbar.uc.css" ]] || fail 'unselected profile modified'
[[ "$(load_saved_profile)" -ef "$first" ]] || fail 'uninstall forgot a different saved profile'

printf 'local edit\n' > "$first/chrome/JS/replace-new-tab.uc.js"
ln -s "$first" "$TEST_DIR/profile alias"
bash "$REPO_DIR/uninstall.sh" --profile "$TEST_DIR/profile alias" > "$TEST_DIR/uninstall.log" 2>&1
[[ ! -e "$first/chrome/JS/replace-new-tab.uc.js" && ! -e "$first/chrome/CSS/firefox-floating-urlbar.uc.css" ]] || fail 'profile alias uninstall failed'
[[ ! -e "$SAVED_PROFILE_FILE" ]] || fail 'profile alias left remembered state'
backups=("$first/chrome/JS/replace-new-tab.uc.js.bak-"*)
[[ ${#backups[@]} == 1 && "$(cat "${backups[0]}")" == 'local edit' ]] || fail 'edited payload backup lost'
for profile in "$first" "$second"; do
    [[ "$(cat "$profile/prefs.js")" == 'preserve preferences' ]] || fail 'preferences modified'
    [[ "$(cat "$profile/chrome/utils/boot.sys.mjs")" == 'preserve loader' ]] || fail 'shared loader modified'
done
[[ "$(cat "$resources/config.js")" == '// existing startup' ]] || fail 'shared startup modified'

# macOS supplies shasum; force the installer's fallback even if Homebrew adds sha256sum.
(
    command() {
        if [[ "$*" == '-v sha256sum' ]]; then return 1; fi
        builtin command "$@"
    }
    expected="$(shasum -a 256 "$first/prefs.js" | awk '{ print $1 }')"
    [[ "$(autoconfig_sha256 "$first/prefs.js")" == "$expected" ]] || fail 'native shasum fallback failed'
)

case_alias="$PROFILE_ROOT/Profiles/PROFILE [é] WITH SPACES"
if [[ -d "$case_alias" ]]; then
    save_profile "$case_alias"
    bash "$REPO_DIR/uninstall.sh" --profile "$first" > "$TEST_DIR/uninstall.log" 2>&1
    [[ ! -e "$SAVED_PROFILE_FILE" ]] || fail 'case-insensitive profile alias left state'
    echo 'PASS: case-insensitive profile identity.'
else
    echo 'INFO: case-sensitive volume; case variants are distinct profiles.'
fi
echo "macOS regressions passed ($(uname -m), native filesystem/BSD tools, temporary app bundle and profiles; no Firefox GUI or elevation)."

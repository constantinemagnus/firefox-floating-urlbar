#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
TEST_DIR="$(cd -- "$TEST_DIR" && pwd -P)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
export XDG_CONFIG_HOME="$TEST_DIR/config"
# shellcheck source=../lib.sh
source "$REPO_DIR/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Catches: a broken profiles.ini parser (CRLF line endings, relative vs absolute
# paths, spaces) installing into the wrong folder.
mkdir -p "$TEST_DIR/ini" "$TEST_DIR/absolute profile"
printf '[Profile0]\r\nName=Test\r\nIsRelative=0\r\nPath=%s\r\n' "$TEST_DIR/absolute profile" > "$TEST_DIR/ini/profiles.ini"
[[ "$(list_profiles_from_ini "$TEST_DIR/ini" | tr '\0' '\n')" == "$(printf '%s\n' Test "$TEST_DIR/absolute profile" "$TEST_DIR/absolute profile")" ]] || fail "absolute CRLF profile"
printf '[Profile0]\r\nName=Test\r\nIsRelative=1\r\nPath=relative\r\n' > "$TEST_DIR/ini/profiles.ini"
[[ "$(list_profiles_from_ini "$TEST_DIR/ini" | tr '\0' '\n')" == "$(printf '%s\n' Test "$TEST_DIR/ini/relative" relative)" ]] || fail "relative CRLF profile"

# Catches: profile names with shell-special characters being mangled in the menu
# or the selected path, and closed input silently picking a profile.
mkdir -p "$TEST_DIR/ini/Work|Personal" "$TEST_DIR/ini/other"
mkdir -p "$TEST_DIR/ini/Work|Personal/chrome/utils"
touch "$TEST_DIR/ini/Work|Personal/chrome/utils/boot.sys.mjs" "$TEST_DIR/ini/Work|Personal/chrome/utils/chrome.manifest"
touch "$TEST_DIR/ini/Work|Personal/prefs.js" "$TEST_DIR/ini/other/prefs.js"
printf '[Profile0]\nName=Work|Personal\nPath=Work|Personal\n[Profile1]\nName=Other\nPath=other\n' > "$TEST_DIR/ini/profiles.ini"
choose_profile "$TEST_DIR/ini" <<< 1 > "$TEST_DIR/pipe-menu"
[[ "$PROFILE" == "$TEST_DIR/ini/Work|Personal" ]] || fail 'pipe in profile path corrupted'
grep -Fq 'Work|Personal' "$TEST_DIR/pipe-menu" || fail 'pipe in profile name corrupted'
if (choose_profile "$TEST_DIR/ini" </dev/null) > "$TEST_DIR/eof.log" 2>&1; then fail 'profile EOF accepted'; fi
grep -q 'No profile selected.*--profile' "$TEST_DIR/eof.log" || fail 'profile EOF explanation missing'

# Catches: missing or stale profiles.ini hiding profiles kept in Profiles/ (macOS).
mkdir -p "$TEST_DIR/fallback/Profiles/nested profile" "$TEST_DIR/fallback/unused"
touch "$TEST_DIR/fallback/Profiles/nested profile/prefs.js"
choose_profile "$TEST_DIR/fallback" >/dev/null
[[ "$PROFILE" == "$TEST_DIR/fallback/Profiles/nested profile" ]] || fail "nested profile fallback"
printf '[Profile0]\nName=Stale\nPath=missing\n' > "$TEST_DIR/fallback/profiles.ini"
choose_profile "$TEST_DIR/fallback" >/dev/null
[[ "$PROFILE" == "$TEST_DIR/fallback/Profiles/nested profile" ]] || fail "stale ini nested profile fallback"
mkdir "$TEST_DIR/fallback/direct profile"
touch "$TEST_DIR/fallback/direct profile/prefs.js"
choose_profile "$TEST_DIR/fallback" "$TEST_DIR/fallback/direct profile" <<< '' > "$TEST_DIR/fallback-menu"
[[ "$PROFILE" == "$TEST_DIR/fallback/direct profile" ]] || fail "mixed direct and nested profile fallback"
grep -Fq "$TEST_DIR/fallback/Profiles/nested profile" "$TEST_DIR/fallback-menu" || fail "mixed fallback omitted nested profile"

# Catches: saved relative paths resolving against the wrong directory later.
mkdir -p "$TEST_DIR/caller/profile"
(cd "$TEST_DIR/caller"; save_profile profile)
[[ "$(load_saved_profile)" == "$TEST_DIR/caller/profile" ]] || fail "relative profile persistence"
printf 'profile\n' > "$SAVED_PROFILE_FILE"
if (cd "$TEST_DIR/caller"; load_saved_profile); then fail "ambiguous legacy relative path accepted"; fi

# Catches: overwriting an edited payload without a backup, losing a backup when
# two runs share a timestamp, or overwriting after the backup failed.
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
printf 'must survive' > "$TEST_DIR/preserved"
if (
    cp() { printf 'partial backup' > "${@: -1}"; return 1; }
    copy_with_backup "$TEST_DIR/source" "$TEST_DIR/preserved"
) > "$TEST_DIR/backup-failure.log" 2>&1; then fail "backup failure accepted"; fi
[[ "$(cat "$TEST_DIR/preserved")" == 'must survive' ]] || fail "overwrote after backup failure"
if compgen -G "$TEST_DIR/preserved.bak-*" >/dev/null; then fail "failed copy left an incomplete backup"; fi

# Catches: clearing another profile's cache that shares the folder name.
mkdir -p "$TEST_DIR/cache-a/same-name/startupCache" "$TEST_DIR/cache-b/same-name/startupCache"
printf 'other profile' > "$TEST_DIR/cache-b/same-name/startupCache/sentinel"
clear_startup_cache "$TEST_DIR/cache-a/same-name" >/dev/null
[[ ! -e "$TEST_DIR/cache-a/same-name/startupCache" ]] || fail "selected cache not cleared"
[[ -f "$TEST_DIR/cache-b/same-name/startupCache/sentinel" ]] || fail "deleted same-basename profile cache"

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
# Catches: uninstall ignoring --root/--profile and removing the saved profile's
# files instead, or forgetting the saved profile when removing another one.
save_profile "$PROFILE_A"
bash "$REPO_DIR/uninstall.sh" --root "$TEST_DIR/root-b" > "$TEST_DIR/uninstall.log" 2>&1
[[ -f "$PROFILE_A/chrome/JS/replace-new-tab.uc.js" ]] || fail "uninstalled saved profile despite explicit root"
[[ ! -f "$PROFILE_B/chrome/JS/replace-new-tab.uc.js" ]] || fail "explicit uninstall root ignored"
[[ "$(load_saved_profile)" == "$PROFILE_A" ]] || fail "uninstall B forgot saved profile A"
bash "$REPO_DIR/uninstall.sh" --profile "$PROFILE_B" > "$TEST_DIR/repeat-uninstall.log" 2>&1
[[ "$(load_saved_profile)" == "$PROFILE_A" ]] || fail "repeat uninstall B forgot A"
(cd "$TEST_DIR/root-b"; bash "$REPO_DIR/install.sh" --profile profile-b > "$TEST_DIR/install.log" 2>&1)
[[ "$(load_saved_profile)" == "$PROFILE_B" ]] || fail "installer did not save absolute path"
ln -s "$PROFILE_B" "$TEST_DIR/profile alias"
bash "$REPO_DIR/uninstall.sh" --profile "$TEST_DIR/profile alias" > "$TEST_DIR/alias-uninstall.log" 2>&1
[[ ! -e "$SAVED_PROFILE_FILE" ]] || fail "uninstall alias did not clear matching saved profile"

# Catches: bare uninstall reusing the saved profile without asking, accepting an
# invalid choice, or touching the unselected profile, prefs or loader.
choice_root="$TEST_DIR/choose-root"
mkdir -p "$choice_root"
cp -a "$PROFILE_A" "$choice_root/first"
cp -a "$PROFILE_A" "$choice_root/second"
printf '[Profile0]\nName=First\nIsRelative=1\nPath=first\n[Profile1]\nName=Second\nIsRelative=1\nPath=second\n' > "$choice_root/profiles.ini"
save_profile "$PROFILE_A"
if printf '0\n' | PROFILE_ROOT="$choice_root" bash "$REPO_DIR/uninstall.sh" > "$TEST_DIR/invalid-choice.log" 2>&1; then
    fail "uninstall accepted invalid profile selection"
fi
[[ -f "$choice_root/first/chrome/JS/replace-new-tab.uc.js" && -f "$choice_root/second/chrome/JS/replace-new-tab.uc.js" ]] || fail "invalid selection removed files"
printf '2\n' | PROFILE_ROOT="$choice_root" bash "$REPO_DIR/uninstall.sh" > "$TEST_DIR/choose-uninstall.log" 2>&1
[[ -f "$PROFILE_A/chrome/JS/replace-new-tab.uc.js" ]] || fail "bare uninstall silently reused saved profile"
[[ -f "$choice_root/first/chrome/JS/replace-new-tab.uc.js" && -f "$choice_root/first/chrome/CSS/firefox-floating-urlbar.uc.css" ]] || fail "uninstall changed unselected profile"
[[ ! -f "$choice_root/second/chrome/JS/replace-new-tab.uc.js" && ! -f "$choice_root/second/chrome/CSS/firefox-floating-urlbar.uc.css" ]] || fail "uninstall ignored chosen profile"
[[ -f "$choice_root/second/prefs.js" && -f "$choice_root/second/chrome/utils/boot.sys.mjs" ]] || fail "uninstall removed preferences or shared loader"
[[ "$(load_saved_profile)" == "$PROFILE_A" ]] || fail "choosing another profile forgot saved profile"

# Catches: a remembered profile outside the discovered root becoming unselectable.
choose_profile "$choice_root" "$PROFILE_A" <<< '' > "$TEST_DIR/preferred-choice.log"
[[ "$PROFILE" -ef "$PROFILE_A" ]] || fail "chooser ignored remembered profile outside discovered root"
chooser_repo="$TEST_DIR/uninstall-discovery-fixture"
mkdir -p "$chooser_repo"
cp "$REPO_DIR/uninstall.sh" "$REPO_DIR/autoconfig.sh" "$REPO_DIR/fx-autoconfig.conf" "$chooser_repo/"
cat "$REPO_DIR/lib.sh" > "$chooser_repo/lib.sh"
cat >> "$chooser_repo/lib.sh" <<'FIXTURE'
find_profile_root() {
    [[ -n "${TEST_UNINSTALL_ROOT:-}" ]] || return 1
    printf '%s\n' "$TEST_UNINSTALL_ROOT"
}
FIXTURE
for discovery in found missing; do
    custom_profile="$TEST_DIR/custom-$discovery/profile"
    mkdir -p "$(dirname "$custom_profile")"
    cp -a "$PROFILE_A" "$custom_profile"
    save_profile "$custom_profile"
    TEST_UNINSTALL_ROOT="$([[ "$discovery" == found ]] && echo "$choice_root")" \
        bash "$chooser_repo/uninstall.sh" <<< '' > "$TEST_DIR/custom-$discovery.log" 2>&1
    [[ ! -f "$custom_profile/chrome/JS/replace-new-tab.uc.js" ]] || fail "bare uninstall lost custom profile with $discovery discovery"
    [[ -f "$choice_root/first/chrome/JS/replace-new-tab.uc.js" ]] || fail "remembered default removed a discovered profile"
    [[ -f "$custom_profile/prefs.js" && -f "$custom_profile/chrome/utils/boot.sys.mjs" ]] || fail "custom-root uninstall removed preferences or shared loader"
done

# update.sh with a Git stand-in whose upstream moves from bbbbb to ccccc after the
# first lookup. Catches: installing a revision other than the one shown for review,
# fetching twice, dropping or overriding forwarded arguments, and updating on EOF
# or when the local branch is ahead.
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
    merge-base)
        [[ "$*" == 'merge-base --is-ancestor bbbbb aaaaa' ]]
        [[ "${TEST_GIT_SCENARIO:-behind}" == ahead ]] ;;
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
(( $(wc -l < "$TEST_INSTALL_TRACE") == 1 )) || fail "choose reused saved profile"
grep -q 'git diff aaaaa bbbbb$' "$TEST_DIR/update.log" || fail 'update review omitted installer changes'
rm -f -- "$TEST_GIT_TRACE" "$TEST_INSTALL_TRACE" "$TEST_UPSTREAM_QUERIED"
bash "$TEST_DIR/updater/update.sh" </dev/null > "$TEST_DIR/update-eof.log" 2>&1
grep -q 'Cancelled (input closed)' "$TEST_DIR/update-eof.log" || fail 'update EOF explanation missing'
[[ ! -e "$TEST_INSTALL_TRACE" ]] || fail 'update EOF installed changes'
if grep -q '^merge ' "$TEST_GIT_TRACE"; then fail 'update EOF merged changes'; fi
check_update --firefox-dir '/temporary Firefox'
[[ "$(sed -n '2,3p' "$TEST_INSTALL_TRACE")" == "$(printf '%s\n' --firefox-dir '/temporary Firefox')" ]] || fail "Firefox directory not forwarded"
[[ "$(sed -n '4,5p' "$TEST_INSTALL_TRACE")" == "$(printf '%s\n' --profile "$PROFILE_A")" ]] || fail "Firefox directory suppressed saved profile"
export PROFILE_ROOT="$TEST_DIR/root-b"
check_update
(( $(wc -l < "$TEST_INSTALL_TRACE") == 1 )) || fail "environment root overridden"

rm -f -- "$TEST_GIT_TRACE" "$TEST_INSTALL_TRACE" "$TEST_UPSTREAM_QUERIED"
if TEST_GIT_SCENARIO=ahead bash "$TEST_DIR/updater/update.sh" --yes > "$TEST_DIR/ahead.log" 2>&1; then
    fail "ahead branch accepted"
fi
[[ ! -e "$TEST_INSTALL_TRACE" ]] || fail "ahead branch installed unreviewed revision"
if grep -Eq '^(merge |--no-pager )' "$TEST_GIT_TRACE"; then fail "ahead branch previewed or merged older upstream"; fi
grep -q 'ahead of upstream.*install.sh' "$TEST_DIR/ahead.log" || fail "ahead branch guidance missing"


# Catches: tests/run.sh hiding a failing suite's output or exit code.
runner_fixture="$TEST_DIR/runner fixture"
mkdir -p "$runner_fixture/tests" "$runner_fixture/bin" "$runner_fixture/logs"
cp "$REPO_DIR/tests/run.sh" "$runner_fixture/tests/"
printf '#!/bin/sh\nprintf "# tests 1\\n"\n' > "$runner_fixture/bin/node"
printf 'printf "shell diagnostic\\n" >&2\nexit 37\n' > "$runner_fixture/tests/shell.test.sh"
chmod +x "$runner_fixture/bin/node"
runner_status=0
PATH="$runner_fixture/bin:$PATH" TMPDIR="$runner_fixture/logs" \
    bash "$runner_fixture/tests/run.sh" > "$TEST_DIR/runner.log" 2>&1 || runner_status=$?
[[ "$runner_status" == 37 ]] || fail "runner changed the failing exit code"
grep -q 'shell diagnostic' "$TEST_DIR/runner.log" || fail 'runner hid failure output'

echo "Shell regressions passed (temporary profiles and mocked Git; no real profile or repository updated)."
bash "$REPO_DIR/tests/autoconfig.test.sh"
bash "$REPO_DIR/tests/remote-install.test.sh"

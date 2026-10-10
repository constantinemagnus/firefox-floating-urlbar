#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
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

# A failed backup must stop the overwrite, including in a conditional caller
# where Bash does not apply errexit inside the helper.
printf 'must survive' > "$TEST_DIR/preserved"
if (
    cp() { return 1; }
    copy_with_backup "$TEST_DIR/source" "$TEST_DIR/preserved"
) > "$TEST_DIR/backup-failure.log" 2>&1; then fail "backup failure accepted"; fi
[[ "$(cat "$TEST_DIR/preserved")" == 'must survive' ]] || fail "overwrote after backup failure"

# Reject linked and non-file destinations without following or nesting copies.
printf 'unrelated user data' > "$TEST_DIR/unrelated"
ln -s "$TEST_DIR/unrelated" "$TEST_DIR/symlink"
ln -s "$TEST_DIR/absent-target" "$TEST_DIR/dangling"
ln "$TEST_DIR/unrelated" "$TEST_DIR/hardlink"
mkdir "$TEST_DIR/directory"
mkfifo "$TEST_DIR/fifo"
for kind in symlink dangling hardlink directory fifo; do
    if (copy_with_backup "$TEST_DIR/source" "$TEST_DIR/$kind") > "$TEST_DIR/destination.log" 2>&1; then
        fail "accepted $kind destination"
    fi
done
[[ "$(cat "$TEST_DIR/unrelated")" == 'unrelated user data' ]] || fail "modified link target"
[[ ! -e "$TEST_DIR/absent-target" ]] || fail "created dangling link target"
[[ ! -e "$TEST_DIR/directory/source" ]] || fail "copied into destination directory"
if (
    # Invoked indirectly by the library's destination check.
    # shellcheck disable=SC2329
    stat() { return 1; }
    copy_with_backup "$TEST_DIR/source" "$TEST_DIR/preserved"
) > "$TEST_DIR/stat-failure.log" 2>&1; then fail "failed link inspection accepted"; fi
[[ "$(cat "$TEST_DIR/preserved")" == 'must survive' ]] || fail "overwrote after inspection failure"

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
[[ "$(load_saved_profile)" == "$PROFILE_A" ]] || fail "uninstall B forgot saved profile A"
bash "$REPO_DIR/uninstall.sh" --profile "$PROFILE_B" > "$TEST_DIR/repeat-uninstall.log" 2>&1
[[ "$(load_saved_profile)" == "$PROFILE_A" ]] || fail "repeat uninstall B forgot A"
(cd "$TEST_DIR/root-b"; bash "$REPO_DIR/install.sh" --profile profile-b > "$TEST_DIR/install.log" 2>&1)
[[ "$(load_saved_profile)" == "$PROFILE_B" ]] || fail "installer did not save absolute path"
ln -s "$PROFILE_B" "$TEST_DIR/profile alias"
bash "$REPO_DIR/uninstall.sh" --profile "$TEST_DIR/profile alias" > "$TEST_DIR/alias-uninstall.log" 2>&1
[[ ! -e "$SAVED_PROFILE_FILE" ]] || fail "uninstall alias did not clear matching saved profile"

# Empty explicit values must fail before discovery or Git. Include a safe root
# or profile in every invocation so a regression cannot choose a real profile.
save_profile "$PROFILE_A"
for script in install.sh uninstall.sh update.sh; do
    for option in --profile -p; do
        if bash "$REPO_DIR/$script" --root "$TEST_DIR/root-a" "$option" '' > "$TEST_DIR/empty.log" 2>&1; then
            fail "$script accepted empty $option"
        fi
        [[ "$(cat "$SAVED_PROFILE_FILE")" == "$PROFILE_A" ]] || fail "empty argument changed saved profile"
    done
    if bash "$REPO_DIR/$script" --root "$TEST_DIR/root-a" '' > "$TEST_DIR/empty.log" 2>&1; then
        fail "$script accepted empty positional profile"
    fi
    if bash "$REPO_DIR/$script" --profile "$PROFILE_A" --root '' > "$TEST_DIR/empty.log" 2>&1; then
        fail "$script accepted empty root"
    fi
done

make_profile() {
    local profile="$1" file
    mkdir -p "$profile/chrome/JS" "$profile/chrome/CSS" "$profile/chrome/utils"
    printf 'untouched prefs\n' > "$profile/prefs.js"
    for file in boot.sys.mjs chrome.manifest utils.sys.mjs fs.sys.mjs; do touch "$profile/chrome/utils/$file"; done
}

# Preflight both destinations and their parents: a bad CSS path must not allow
# an earlier JS overwrite. Test uninstall too, so directory links cannot redirect
# removals into another user's files. All outside targets remain inside TEST_DIR.
for kind in symlink dangling hardlink directory fifo parent-symlink chrome-symlink; do
    attack_profile="$TEST_DIR/attack-$kind/profile with spaces"
    outside="$TEST_DIR/outside-$kind"
    make_profile "$attack_profile"
    mkdir -p "$outside"
    printf 'original JS\n' > "$attack_profile/chrome/JS/replace-new-tab.uc.js"
    printf 'outside CSS\n' > "$outside/firefox-floating-urlbar.uc.css"
    css_dest="$attack_profile/chrome/CSS/firefox-floating-urlbar.uc.css"
    case "$kind" in
        symlink) ln -s "$outside/firefox-floating-urlbar.uc.css" "$css_dest" ;;
        dangling) ln -s "$outside/absent" "$css_dest" ;;
        hardlink) ln "$outside/firefox-floating-urlbar.uc.css" "$css_dest" ;;
        directory) mkdir "$css_dest" ;;
        fifo) mkfifo "$css_dest" ;;
        parent-symlink)
            rmdir "$attack_profile/chrome/CSS"
            ln -s "$outside" "$attack_profile/chrome/CSS" ;;
        chrome-symlink)
            mv "$attack_profile/chrome" "$outside/chrome"
            ln -s "$outside/chrome" "$attack_profile/chrome" ;;
    esac
    for script in install.sh uninstall.sh; do
        if bash "$REPO_DIR/$script" --profile "$attack_profile" > "$TEST_DIR/attack.log" 2>&1; then
            fail "$script accepted $kind profile destination"
        fi
    done
    [[ "$(cat "$attack_profile/chrome/JS/replace-new-tab.uc.js")" == 'original JS' ]] || fail "$kind changed JS before preflight"
    [[ "$(cat "$outside/firefox-floating-urlbar.uc.css")" == 'outside CSS' ]] || fail "$kind changed outside CSS"
    [[ ! -e "$outside/absent" ]] || fail "$kind created outside target"
    [[ "$(load_saved_profile)" == "$PROFILE_A" ]] || fail "$kind changed saved profile"
done

# A backup write failure must also stop both top-level commands before unlinking
# or overwriting either payload. The failing cp is scoped to this fixture.
preservation_profile="$TEST_DIR/backup failure/profile"
make_profile "$preservation_profile"
printf 'preserve installed JS\n' > "$preservation_profile/chrome/JS/replace-new-tab.uc.js"
printf 'preserve installed CSS\n' > "$preservation_profile/chrome/CSS/firefox-floating-urlbar.uc.css"
mkdir "$TEST_DIR/failing-copy-bin"
printf '#!/bin/sh\nexit 1\n' > "$TEST_DIR/failing-copy-bin/cp"
chmod +x "$TEST_DIR/failing-copy-bin/cp"
for script in install.sh uninstall.sh; do
    if PATH="$TEST_DIR/failing-copy-bin:$PATH" bash "$REPO_DIR/$script" --profile "$preservation_profile" > "$TEST_DIR/preservation.log" 2>&1; then
        fail "$script accepted backup write failure"
    fi
    [[ "$(cat "$preservation_profile/chrome/JS/replace-new-tab.uc.js")" == 'preserve installed JS' ]] || fail "$script lost JS on backup failure"
    [[ "$(cat "$preservation_profile/chrome/CSS/firefox-floating-urlbar.uc.css")" == 'preserve installed CSS' ]] || fail "$script lost CSS on backup failure"
    [[ "$(load_saved_profile)" == "$PROFILE_A" ]] || fail "$script changed saved profile on backup failure"
done

# Persisted state is another write destination: linked records must not clobber
# an unrelated file even when save_profile is used directly.
for kind in symlink hardlink; do
    if (
        SAVED_PROFILE_FILE="$TEST_DIR/saved-$kind"
        if [[ "$kind" == symlink ]]; then ln -s "$TEST_DIR/unrelated" "$SAVED_PROFILE_FILE";
        else ln "$TEST_DIR/unrelated" "$SAVED_PROFILE_FILE"; fi
        save_profile "$PROFILE_A"
    ) > "$TEST_DIR/saved-link.log" 2>&1; then fail "accepted linked saved-profile record"; fi
done
[[ "$(cat "$TEST_DIR/unrelated")" == 'unrelated user data' ]] || fail "overwrote saved-record target"

# Only the selected profile's own real cache directory is eligible. A guarded
# rm prevents a future regression from deleting anything outside these fixtures.
safe_clear_cache() (
    rm() {
        local target="${*: -1}"
        [[ "$target" == "$TEST_DIR/"* ]] || fail "cache deletion escaped fixtures: $target"
        command rm "$@"
    }
    clear_startup_cache "$1"
)
cache_a="$TEST_DIR/cache-a/same-name"
cache_b="$TEST_DIR/cache-b/same-name"
mkdir -p "$cache_a/startupCache" "$cache_b/startupCache" "$TEST_DIR/outside-cache"
printf 'other profile' > "$cache_b/startupCache/sentinel"
printf 'outside data' > "$TEST_DIR/outside-cache/sentinel"
ln -s "$TEST_DIR/outside-cache" "$cache_a/startupCache/linked-child"
safe_clear_cache "$cache_a" > "$TEST_DIR/cache.log"
[[ ! -e "$cache_a/startupCache" ]] || fail "selected cache not cleared"
[[ -f "$cache_b/startupCache/sentinel" ]] || fail "deleted same-basename profile cache"
[[ -f "$TEST_DIR/outside-cache/sentinel" ]] || fail "followed child link while clearing cache"
ln -s "$TEST_DIR/outside-cache" "$cache_a/startupCache"
if safe_clear_cache "$cache_a" > "$TEST_DIR/cache.log" 2>&1; then fail "accepted symlink cache"; fi
[[ -f "$TEST_DIR/outside-cache/sentinel" ]] || fail "deleted linked cache target"
rm "$cache_a/startupCache"
printf 'ordinary file' > "$cache_a/startupCache"
if safe_clear_cache "$cache_a" > "$TEST_DIR/cache.log" 2>&1; then fail "accepted non-directory cache"; fi
[[ "$(cat "$cache_a/startupCache")" == 'ordinary file' ]] || fail "deleted non-directory cache"
rm "$cache_a/startupCache"
mkdir "$cache_a/startupCache"
for failure in nonzero no-removal; do
    if (
        if [[ "$failure" == nonzero ]]; then rm() { return 1; };
        else rm() { return 0; }; fi
        clear_startup_cache "$cache_a"
    ) > "$TEST_DIR/cache-failure.log" 2>&1; then fail "cache failure reported success: $failure"; fi
    if grep -q '^Cleared startup cache:' "$TEST_DIR/cache-failure.log"; then fail "false cache success message"; fi
    grep -q 'Could not clear startup cache:' "$TEST_DIR/cache-failure.log" || fail "cache failure not reported"
done

# A closed Firefox exercises the installer's manual guidance for unverified
# caches. The profile is disposable; no external cache path should be touched.
printf '#!/bin/sh\nexit 1\n' > "$TEST_DIR/bin/pgrep"
bash "$REPO_DIR/install.sh" --profile "$PROFILE_A" > "$TEST_DIR/cache-guidance.log" 2>&1
grep -q 'Startup cache not cleared automatically.*about:support' "$TEST_DIR/cache-guidance.log" || fail "missing cache guidance"
printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/bin/pgrep"

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
[[ "$(wc -l < "$TEST_INSTALL_TRACE")" == 1 ]] || fail "choose reused saved profile"
export PROFILE_ROOT="$TEST_DIR/root-b"
check_update
[[ "$(wc -l < "$TEST_INSTALL_TRACE")" == 1 ]] || fail "environment root overridden"

rm -f -- "$TEST_GIT_TRACE" "$TEST_INSTALL_TRACE" "$TEST_UPSTREAM_QUERIED"
if TEST_GIT_SCENARIO=ahead bash "$TEST_DIR/updater/update.sh" --yes > "$TEST_DIR/ahead.log" 2>&1; then
    fail "ahead branch accepted"
fi
[[ ! -e "$TEST_INSTALL_TRACE" ]] || fail "ahead branch installed unreviewed revision"
if grep -Eq '^(merge |--no-pager )' "$TEST_GIT_TRACE"; then fail "ahead branch previewed or merged older upstream"; fi
grep -q 'ahead of upstream.*install.sh' "$TEST_DIR/ahead.log" || fail "ahead branch guidance missing"

echo "Shell regressions passed (temporary profiles and mocked Git; no real profile or repository updated)."

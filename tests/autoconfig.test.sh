#!/usr/bin/env bash
# fx-autoconfig setup and cleanup in install.sh/uninstall.sh, against a fixture
# archive served by a stub curl. No real profile, Firefox or network is used.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
TEST_DIR="$(cd -- "$TEST_DIR" && pwd -P)"
trap 'test_status=$?; if (( test_status )); then tail -n 40 "$TEST_DIR"/*.log 2>/dev/null || true; fi; rm -rf -- "$TEST_DIR"; exit "$test_status"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Catches: the Arch package, Bash and PowerShell installers drifting to different
# upstream snapshots or loader file lists.
(
    # shellcheck source=../fx-autoconfig.conf
    source "$REPO_DIR/fx-autoconfig.conf"
    # shellcheck source=../packaging/fx-autoconfig/PKGBUILD
    source "$REPO_DIR/packaging/fx-autoconfig/PKGBUILD"
    [[ "$_commit" == "$AUTOCONFIG_COMMIT" && "${sha256sums[0]}" == "$AUTOCONFIG_TAR_SHA256" ]] || fail 'Arch and installer source pins differ'
    source "$REPO_DIR/autoconfig.sh"
    powershell_modules="$(sed -n 's/^\$AutoconfigModules = @(\(.*\))$/\1/p' "$REPO_DIR/install.ps1" | tr -d "',")"
    [[ "$powershell_modules" == "${AUTOCONFIG_MODULES[*]}" ]] || fail 'Bash and PowerShell loader file lists differ'
)

mkdir -p "$TEST_DIR/checkout/JS" "$TEST_DIR/checkout/CSS" "$TEST_DIR/bin"
cp "$REPO_DIR/"{install.sh,uninstall.sh,lib.sh,autoconfig.sh} "$TEST_DIR/checkout/"
cp "$REPO_DIR/JS/replace-new-tab.uc.js" "$TEST_DIR/checkout/JS/"
cp "$REPO_DIR/CSS/firefox-floating-urlbar.uc.css" "$TEST_DIR/checkout/CSS/"

# Builds a fixture snapshot for COMMIT and pins the checkout to it.
make_snapshot() {
    local commit="$1" fixture="$TEST_DIR/source-$1/fx-autoconfig-$1" file
    mkdir -p "$fixture/program/defaults/pref" "$fixture/profile/chrome/utils"
    printf 'fixture MPL-2.0 license\n' > "$fixture/LICENSE"
    printf '// fixture startup %s\n' "$commit" > "$fixture/program/config.js"
    printf 'pref("general.config.filename", "config.js");\n' > "$fixture/program/defaults/pref/config-prefs.js"
    for file in boot.sys.mjs fs.sys.mjs utils.sys.mjs uc_api.sys.mjs module_loader.mjs chrome.manifest; do
        printf 'fixture %s %s\n' "$commit" "$file" > "$fixture/profile/chrome/utils/$file"
    done
    tar -czf "$TEST_DIR/$commit.tar.gz" -C "$TEST_DIR/source-$1" "fx-autoconfig-$commit"
    export TEST_AUTOCONFIG_ARCHIVE="$TEST_DIR/$commit.tar.gz"
    printf 'AUTOCONFIG_COMMIT=%s\nAUTOCONFIG_TAR_SHA256=%s\n' "$commit" \
        "$(source "$REPO_DIR/lib.sh"; source "$REPO_DIR/autoconfig.sh"; autoconfig_sha256 "$TEST_AUTOCONFIG_ARCHIVE")" \
        > "$TEST_DIR/checkout/fx-autoconfig.conf"
    snapshot="$fixture"
}
make_snapshot first

export TEST_DOWNLOAD_TRACE="$TEST_DIR/downloads.trace" TEST_SUDO_TRACE="$TEST_DIR/sudo.trace"
cat > "$TEST_DIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "${*: -3:1}" >> "$TEST_DOWNLOAD_TRACE"
while (( $# )); do
    if [[ "$1" == --output ]]; then cp "$TEST_AUTOCONFIG_ARCHIVE" "$2"; exit; fi
    shift
done
exit 1
CURL
# Records elevation, then runs the command as this user (tests make the
# directory read-only only through the -w check, see the sudo case below).
cat > "$TEST_DIR/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_SUDO_TRACE"
chmod u+w "$TEST_FIREFOX_LOCKED"
"$@"; status=$?
chmod u-w "$TEST_FIREFOX_LOCKED"
exit "$status"
SUDO
printf '#!/bin/sh\nexit 1\n' > "$TEST_DIR/bin/pgrep"
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH" XDG_CONFIG_HOME="$TEST_DIR/config"

make_case() {
    profile="$TEST_DIR/$1/profile with spaces"
    firefox="$TEST_DIR/$1/Firefox"
    mkdir -p "$profile" "$firefox"
    printf 'unchanged prefs\n' > "$profile/prefs.js"
    printf '[App]\n' > "$firefox/application.ini"
    printf '#!/bin/sh\nexit 0\n' > "$firefox/firefox"
    chmod +x "$firefox/firefox"
    rm -f -- "$TEST_DOWNLOAD_TRACE" "$TEST_SUDO_TRACE"
}
run_install() {
    bash "$TEST_DIR/checkout/install.sh" --profile "$profile" --firefox-dir "$firefox" > "$TEST_DIR/install.log" 2>&1
}
run_uninstall() {
    bash "$TEST_DIR/checkout/uninstall.sh" --profile "$profile" "$@" </dev/null > "$TEST_DIR/uninstall.log" 2>&1
}
downloads() { [[ -f "$TEST_DOWNLOAD_TRACE" ]] && wc -l < "$TEST_DOWNLOAD_TRACE" | tr -d ' ' || echo 0; }
utils() { printf '%s\n' "$profile/chrome/utils"; }

# Catches: a fresh install missing any piece Firefox needs (startup files, loader,
# payloads), fetching the wrong snapshot, or dropping the MPL notice.
make_case fresh
run_install
grep -qx 'https://codeload.github.com/MrOtherGuy/fx-autoconfig/tar.gz/first' "$TEST_DOWNLOAD_TRACE" || fail 'wrong snapshot URL'
cmp "$snapshot/program/config.js" "$firefox/config.js" || fail 'config.js missing'
cmp "$snapshot/program/defaults/pref/config-prefs.js" "$firefox/defaults/pref/config-prefs.js" || fail 'config-prefs.js missing'
[[ -f "$firefox/.floating-urlbar-autoconfig" ]] || fail 'shared files not marked as ours'
cmp "$snapshot/profile/chrome/utils/boot.sys.mjs" "$(utils)/boot.sys.mjs" || fail 'loader missing'
[[ "$(cat "$(utils)/.floating-urlbar-source")" == first ]] || fail 'loader commit not recorded'
cmp "$snapshot/LICENSE" "$(utils)/fx-autoconfig.LICENSE" || fail 'upstream license missing'
cmp "$REPO_DIR/JS/replace-new-tab.uc.js" "$profile/chrome/JS/replace-new-tab.uc.js" || fail 'script missing'
cmp "$REPO_DIR/CSS/firefox-floating-urlbar.uc.css" "$profile/chrome/CSS/firefox-floating-urlbar.uc.css" || fail 'stylesheet missing'

# Catches: reinstalling the same pin downloading again or rewriting shared files.
run_install
[[ "$(downloads)" == 1 ]] || fail 'unchanged reinstall downloaded again'

# Catches: a new pin not updating our loader and our shared startup files.
make_snapshot second
run_install
[[ "$(cat "$(utils)/.floating-urlbar-source")" == second ]] || fail 'loader not upgraded'
cmp "$snapshot/program/config.js" "$firefox/config.js" || fail 'owned config.js not upgraded'

# Catches: a tampered or wrong download being installed.
make_case checksum
# A well-formed archive, so only the checksum can stop it.
cp -R "$TEST_DIR/source-second" "$TEST_DIR/tampered"
printf '// tampered\n' > "$TEST_DIR/tampered/fx-autoconfig-second/program/config.js"
tar -czf "$TEST_DIR/tampered.tar.gz" -C "$TEST_DIR/tampered" fx-autoconfig-second
if TEST_AUTOCONFIG_ARCHIVE="$TEST_DIR/tampered.tar.gz" run_install; then fail 'checksum mismatch accepted'; fi
[[ ! -e "$firefox/config.js" && ! -e "$(utils)/boot.sys.mjs" ]] || fail 'files written after checksum mismatch'

# Catches: overwriting a loader the user installed themselves.
make_case external
mkdir -p "$(utils)"
printf 'their loader\n' > "$(utils)/boot.sys.mjs"
printf 'their manifest\n' > "$(utils)/chrome.manifest"
run_install
[[ "$(downloads)" == 0 && "$(cat "$(utils)/boot.sys.mjs")" == 'their loader' ]] || fail 'external loader replaced'
# Catches: uninstall cleanup deleting a loader we did not install.
run_uninstall --remove-shared-autoconfig --firefox-dir "$firefox"
[[ "$(cat "$(utils)/boot.sys.mjs")" == 'their loader' ]] || fail 'uninstall removed external loader'

# Catches: overriding another browser's AutoConfig (LibreWolf ships its own).
make_case foreign
mkdir -p "$firefox/defaults/pref"
printf 'pref("general.config.filename", "librewolf.cfg");\n' > "$firefox/defaults/pref/librewolf.js"
if run_install; then fail 'foreign AutoConfig accepted'; fi
grep -q 'Another AutoConfig configuration exists' "$TEST_DIR/install.log" || fail 'foreign AutoConfig not explained'
[[ ! -e "$firefox/config.js" ]] || fail 'wrote config.js beside foreign AutoConfig'

# Catches: replacing a startup file someone else created.
make_case unowned
printf '// their config\n' > "$firefox/config.js"
if run_install; then fail 'unowned config.js replaced'; fi
[[ "$(cat "$firefox/config.js")" == '// their config' ]] || fail 'unowned config.js changed'

# Catches: matching startup files we did not create being marked as ours, which
# would let uninstall remove them.
make_case adopted
mkdir -p "$firefox/defaults/pref"
cp "$snapshot/program/config.js" "$firefox/config.js"
run_install
[[ ! -e "$firefox/.floating-urlbar-autoconfig" ]] || fail 'adopted shared files marked as ours'

# Catches: a read-only Firefox directory not being elevated, or elevating
# profile writes. Root can write anywhere, so it cannot see a read-only folder.
make_case sudo
(( EUID != 0 )) || fail 'run this suite as a normal user'
export TEST_FIREFOX_LOCKED="$firefox"
chmod u-w "$firefox"
run_install
chmod u+w "$firefox"
grep -q "config.js $firefox/config.js" "$TEST_SUDO_TRACE" || fail 'startup files not written through sudo'
if grep -q "$profile" "$TEST_SUDO_TRACE"; then fail 'profile written through sudo'; fi

# Catches: optional cleanup breaking other user scripts that rely on the loader.
make_case shared-other
run_install
printf '// another mod\n' > "$profile/chrome/other.uc.js"
if run_uninstall --remove-autoconfig; then fail 'cleanup ignored another customization'; fi
[[ -f "$(utils)/boot.sys.mjs" ]] || fail 'loader removed despite another customization'
# Catches: the same check missing scripts linked in from a dotfiles repository.
mv "$profile/chrome/other.uc.js" "$TEST_DIR/linked.uc.js"
ln -s "$TEST_DIR/linked.uc.js" "$profile/chrome/other.uc.js"
if run_uninstall --remove-autoconfig; then fail 'cleanup ignored a linked customization'; fi
[[ -f "$(utils)/boot.sys.mjs" ]] || fail 'loader removed despite a linked customization'

# Catches: full cleanup leaving our files behind, removing the profile itself, or
# glob characters in the profile path making our own files look like other mods.
make_case 'cleanup [2]'
run_install
run_uninstall --remove-shared-autoconfig --firefox-dir "$firefox"
[[ ! -e "$(utils)" && ! -e "$firefox/config.js" && ! -e "$firefox/defaults/pref/config-prefs.js" &&
   ! -e "$firefox/.floating-urlbar-autoconfig" ]] || fail 'cleanup left fx-autoconfig files'
[[ "$(cat "$profile/prefs.js")" == 'unchanged prefs' ]] || fail 'cleanup changed prefs'

echo "AutoConfig regressions passed (fixture archive, stub curl and sudo)."

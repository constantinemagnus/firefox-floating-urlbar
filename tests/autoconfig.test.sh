#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
TEST_DIR="$(cd -- "$TEST_DIR" && pwd -P)"
trap 'test_status=$?; if (( test_status )); then tail -n 40 "$TEST_DIR"/*.log 2>/dev/null || true; fi; rm -rf -- "$TEST_DIR"; exit "$test_status"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Both distribution paths must fetch the same upstream snapshot.
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
fixture="$TEST_DIR/source/fx-autoconfig-fixture"
mkdir -p "$fixture/program/defaults/pref" "$fixture/profile/chrome/utils"
printf 'fixture MPL-2.0 license\n' > "$fixture/LICENSE"
printf '// fixture startup\n' > "$fixture/program/config.js"
printf 'pref("general.config.filename", "config.js");\n' > "$fixture/program/defaults/pref/config-prefs.js"
for file in boot.sys.mjs fs.sys.mjs utils.sys.mjs uc_api.sys.mjs module_loader.mjs chrome.manifest; do
    printf 'fixture %s\n' "$file" > "$fixture/profile/chrome/utils/$file"
done
export TEST_AUTOCONFIG_ARCHIVE="$TEST_DIR/source.tar.gz"
tar -czf "$TEST_AUTOCONFIG_ARCHIVE" -C "$TEST_DIR/source" fx-autoconfig-fixture
printf 'AUTOCONFIG_COMMIT=fixture\nAUTOCONFIG_TAR_SHA256=%s\n' \
    "$(source "$REPO_DIR/autoconfig.sh"; autoconfig_sha256 "$TEST_AUTOCONFIG_ARCHIVE")" > "$TEST_DIR/checkout/fx-autoconfig.conf"
export TEST_DOWNLOAD_TRACE="$TEST_DIR/downloads"
cat > "$TEST_DIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
printf 'download\n' >> "$TEST_DOWNLOAD_TRACE"
[[ "${TEST_AUTOCONFIG_DOWNLOAD_FAIL:-0}" == 0 ]] || exit 7
while (( $# )); do
    if [[ "$1" == --output ]]; then cp "$TEST_AUTOCONFIG_ARCHIVE" "$2"; exit; fi
    shift
done
exit 1
CURL
printf '#!/bin/sh\nexit "${TEST_FIREFOX_RUNNING:-0}"\n' > "$TEST_DIR/bin/pgrep"
printf '#!/bin/sh\necho "unexpected sudo" >&2\nexit 1\n' > "$TEST_DIR/bin/sudo"
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH" XDG_CONFIG_HOME="$TEST_DIR/config"

make_case() {
    case_profile="$TEST_DIR/$1/profile with spaces"
    case_firefox="$TEST_DIR/$1/Firefox"
    mkdir -p "$case_profile" "$case_firefox"
    printf 'unchanged prefs\n' > "$case_profile/prefs.js"
    printf '[App]\n' > "$case_firefox/application.ini"
    printf '#!/bin/sh\nexit 0\n' > "$case_firefox/firefox"
    chmod +x "$case_firefox/firefox"
}
run_install() {
    bash "$TEST_DIR/checkout/install.sh" --profile "$case_profile" --firefox-dir "$case_firefox" > "$TEST_DIR/install.log" 2>&1
}
run_uninstall() {
    bash "$TEST_DIR/checkout/uninstall.sh" --profile "$case_profile" "$@" </dev/null > "$TEST_DIR/uninstall.log" 2>&1
}

make_case fresh
run_install
cmp "$fixture/program/config.js" "$case_firefox/config.js" || fail 'startup file missing'
cmp "$fixture/program/defaults/pref/config-prefs.js" "$case_firefox/defaults/pref/config-prefs.js" || fail 'startup preferences missing'
[[ "$(cat "$case_profile/chrome/utils/.floating-urlbar-source")" == fixture ]] || fail 'managed loader not recorded'
cmp "$fixture/LICENSE" "$case_profile/chrome/utils/fx-autoconfig.LICENSE" || fail 'upstream license missing or altered'
grep -q 'https://github.com/MrOtherGuy/fx-autoconfig/tree/fixture' "$case_profile/chrome/utils/fx-autoconfig.txt" || fail 'pinned source notice missing'
[[ -f "$case_profile/chrome/JS/replace-new-tab.uc.js" && -f "$case_profile/chrome/CSS/firefox-floating-urlbar.uc.css" ]] || fail 'project payload missing'
[[ "$(cat "$case_profile/prefs.js")" == 'unchanged prefs' ]] || fail 'prefs changed'
run_install
(( $(wc -l < "$TEST_DOWNLOAD_TRACE") == 1 )) || fail 'downloaded again on unchanged reinstall'
[[ -f "$case_profile/chrome/utils/.floating-urlbar-files" && -f "$case_firefox/.floating-urlbar-autoconfig" ]] || fail 'ownership records missing'

# A changed upstream pin may replace only receipt-verified shared startup files.
cp "$TEST_DIR/checkout/fx-autoconfig.conf" "$TEST_DIR/pin-a"
cp -R "$fixture" "$TEST_DIR/source/fx-autoconfig-next"
for file in "$TEST_DIR/source/fx-autoconfig-next/profile/chrome/utils/"*; do
    printf 'next %s\n' "${file##*/}" > "$file"
done
printf '// next startup\n' > "$TEST_DIR/source/fx-autoconfig-next/program/config.js"
printf 'pref("general.config.filename", "config.js"); // next\n' > "$TEST_DIR/source/fx-autoconfig-next/program/defaults/pref/config-prefs.js"
tar -czf "$TEST_DIR/next.tar.gz" -C "$TEST_DIR/source" fx-autoconfig-next
printf 'AUTOCONFIG_COMMIT=next\nAUTOCONFIG_TAR_SHA256=%s\n' \
    "$(source "$REPO_DIR/autoconfig.sh"; autoconfig_sha256 "$TEST_DIR/next.tar.gz")" > "$TEST_DIR/pin-b"
mkdir "$TEST_DIR/startup-failure-bin"
export TEST_STARTUP_REAL_INSTALL TEST_STARTUP_REAL_MV
TEST_STARTUP_REAL_INSTALL="$(command -v install)"
TEST_STARTUP_REAL_MV="$(command -v mv)"
export TEST_ROOT_PID=$$
cat > "$TEST_DIR/startup-failure-bin/install" <<'INSTALL'
#!/usr/bin/env bash
if [[ "${TEST_STARTUP_FAILURE:-}" == stage && "${*: -1}" == */.floating-urlbar-startup.*/new-1 ]]; then exit 13; fi
if [[ "${TEST_STARTUP_FAILURE:-}" == interrupt && "${*: -1}" == */.floating-urlbar-startup.*/new-0 ]]; then
    # Simulate a killed installer: no traps, rollback or cleanup run.
    # Signal the installer's ancestors first; this stub goes last.
    pids=() pid="$(ps -o ppid= -p $$ | tr -d ' ')"
    while [[ "$pid" != "$TEST_ROOT_PID" && "$pid" -gt 1 ]]; do
        pids+=("$pid"); pid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
    done
    kill -KILL "${pids[@]}" $$
fi
exec "$TEST_STARTUP_REAL_INSTALL" "$@"
INSTALL
cat > "$TEST_DIR/startup-failure-bin/cp" <<'CP'
#!/usr/bin/env bash
if [[ "${TEST_STARTUP_FAILURE:-}" == module-stage && "${*: -1}" == */.floating-urlbar-install.*/utils/fs.sys.mjs ]]; then
    printf 'partial copy' > "${*: -1}"
    exit 13
fi
exec "$TEST_REAL_CP" "$@"
CP
export TEST_REAL_CP
TEST_REAL_CP="$(command -v cp)"
cat > "$TEST_DIR/startup-failure-bin/mv" <<'MV'
#!/usr/bin/env bash
src="${@: -2:1}"
if [[ "${TEST_STARTUP_FAILURE:-}" == module-replace && "$src" == */.floating-urlbar-install.*/utils/fs.sys.mjs ]] ||
   [[ "${TEST_STARTUP_FAILURE:-}" == profile-receipt && "$src" == */.floating-urlbar-install.*/utils/.floating-urlbar-files ]]; then
    [[ "$(cat "$(dirname "${*: -1}")/.floating-urlbar-source")" == pending* ]] || exit 14
    printf 'partial replacement' > "${*: -1}"
    exit 13
fi
if [[ "${TEST_STARTUP_FAILURE:-}" == restore && ( "$src" == */.floating-urlbar-install.*/utils/fs.sys.mjs ||
      "$src" == */.floating-urlbar-source.previous ) ]]; then exit 13; fi
if [[ "${TEST_STARTUP_FAILURE:-}" == replace && "$src" == */.floating-urlbar-startup.*/new-1 ]] ||
   [[ "${TEST_STARTUP_FAILURE:-}" == receipt && "$src" == */.floating-urlbar-startup.*/new-2 ]]; then exit 13; fi
exec "$TEST_STARTUP_REAL_MV" "$@"
MV
chmod +x "$TEST_DIR/startup-failure-bin/"*
for state in owned edited unowned fresh; do
    for phase in module-stage module-replace profile-receipt stage replace receipt success; do
        cp "$TEST_DIR/pin-a" "$TEST_DIR/checkout/fx-autoconfig.conf"
        make_case "pin-$state-$phase"
        if [[ "$state" != fresh ]]; then run_install; fi
        if [[ "$state" == edited ]]; then printf '// user edit\n' > "$case_firefox/config.js"; fi
        if [[ "$state" == unowned ]]; then rm "$case_firefox/.floating-urlbar-autoconfig"; fi
        cp -R "$case_firefox" "$TEST_DIR/before-$state-$phase"
        if [[ -d "$case_profile/chrome/utils" ]]; then cp -R "$case_profile/chrome/utils" "$TEST_DIR/loader-before-$state-$phase"; fi
        cp "$TEST_DIR/pin-b" "$TEST_DIR/checkout/fx-autoconfig.conf"
        if TEST_AUTOCONFIG_ARCHIVE="$TEST_DIR/next.tar.gz" TEST_STARTUP_FAILURE="$phase" PATH="$TEST_DIR/startup-failure-bin:$PATH" run_install; then
            [[ "$phase" == success && ( "$state" == owned || "$state" == fresh ) ]] || fail "unsafe pin upgrade succeeded: $state/$phase"
            cmp "$TEST_DIR/source/fx-autoconfig-next/program/config.js" "$case_firefox/config.js" || fail 'pin upgrade kept old startup'
            run_uninstall --remove-shared-autoconfig --firefox-dir "$case_firefox"
        else
            [[ "$phase" != success || "$state" == edited || "$state" == unowned ]] || fail 'owned pin upgrade failed'
            for file in config.js defaults/pref/config-prefs.js .floating-urlbar-autoconfig; do
                if [[ -f "$TEST_DIR/before-$state-$phase/$file" ]]; then
                    cmp "$TEST_DIR/before-$state-$phase/$file" "$case_firefox/$file" || fail "startup rollback lost $file"
                else [[ ! -e "$case_firefox/$file" ]] || fail "startup rollback left $file"; fi
            done
            for file in chrome.manifest boot.sys.mjs fs.sys.mjs utils.sys.mjs uc_api.sys.mjs module_loader.mjs fx-autoconfig.LICENSE fx-autoconfig.txt .floating-urlbar-source .floating-urlbar-files; do
                if [[ -f "$TEST_DIR/loader-before-$state-$phase/$file" ]]; then
                    cmp "$TEST_DIR/loader-before-$state-$phase/$file" "$case_profile/chrome/utils/$file" || fail "loader rollback lost $file: $state/$phase"
                else [[ ! -e "$case_profile/chrome/utils/$file" ]] || fail "loader rollback left $file: $state/$phase"; fi
            done
        fi
        if [[ "$state" == owned && "$phase" != success ]]; then
            TEST_AUTOCONFIG_ARCHIVE="$TEST_DIR/next.tar.gz" run_install
            cmp "$TEST_DIR/source/fx-autoconfig-next/profile/chrome/utils/fs.sys.mjs" "$case_profile/chrome/utils/fs.sys.mjs" || fail 'upgrade retry kept old module'
            cmp "$TEST_DIR/source/fx-autoconfig-next/program/config.js" "$case_firefox/config.js" || fail 'upgrade retry kept old startup'
        fi
        if compgen -G "$case_firefox/.floating-urlbar-startup.*" >/dev/null; then fail 'startup staging leaked'; fi
    done
done

# A killed upgrade stays pending, so the next run also finishes shared startup.
cp "$TEST_DIR/pin-a" "$TEST_DIR/checkout/fx-autoconfig.conf"
make_case pin-interrupt
run_install
cp "$TEST_DIR/pin-b" "$TEST_DIR/checkout/fx-autoconfig.conf"
mkdir -p "$TEST_DIR/interrupt-tmp"
if TMPDIR="$TEST_DIR/interrupt-tmp" TEST_AUTOCONFIG_ARCHIVE="$TEST_DIR/next.tar.gz" TEST_STARTUP_FAILURE=interrupt \
    PATH="$TEST_DIR/startup-failure-bin:$PATH" run_install; then fail 'interrupted upgrade reported success'; fi
cmp -s "$TEST_DIR/source/fx-autoconfig-next/program/config.js" "$case_firefox/config.js" && fail 'interruption came after startup replacement'
[[ "$(cat "$case_profile/chrome/utils/.floating-urlbar-source")" != next ]] || fail 'interrupted upgrade was marked complete'
TEST_AUTOCONFIG_ARCHIVE="$TEST_DIR/next.tar.gz" run_install
cmp "$TEST_DIR/source/fx-autoconfig-next/program/config.js" "$case_firefox/config.js" || fail 'retry after interruption kept old startup'
[[ "$(cat "$case_profile/chrome/utils/.floating-urlbar-source")" == next ]] || fail 'retry after interruption did not complete the marker'

# A failed restore keeps its recovery copy instead of deleting it with staging.
cp "$TEST_DIR/pin-a" "$TEST_DIR/checkout/fx-autoconfig.conf"
make_case pin-restore-failure
run_install
cp "$TEST_DIR/pin-b" "$TEST_DIR/checkout/fx-autoconfig.conf"
if TEST_AUTOCONFIG_ARCHIVE="$TEST_DIR/next.tar.gz" TEST_STARTUP_FAILURE=restore PATH="$TEST_DIR/startup-failure-bin:$PATH" run_install; then
    fail 'upgrade with a failed restore reported success'
fi
recovery=("$case_profile/chrome/.floating-urlbar-install."*/utils/.floating-urlbar-source.previous)
[[ -f "${recovery[0]}" && "$(cat "${recovery[0]}")" == fixture ]] || fail 'failed restore deleted its recovery copy'
grep -qF "${recovery[0]}" "$TEST_DIR/install.log" || fail 'restore warning did not name the surviving recovery copy'
cp "$TEST_DIR/pin-a" "$TEST_DIR/checkout/fx-autoconfig.conf"

# Exercise the real non-writable-directory branch without real privileges.
make_case sudo-path
mkdir -p "$TEST_DIR/recording-sudo"
export TEST_SUDO_FIREFOX="$case_firefox" TEST_SUDO_PROFILE="$case_profile" TEST_SUDO_TRACE="$TEST_DIR/sudo.trace"
cat > "$TEST_DIR/recording-sudo/sudo" <<'SUDO'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
    [[ "$arg" != "$TEST_SUDO_PROFILE"* ]] || { echo 'elevation included profile writes' >&2; exit 1; }
done
printf '%s\n' "$@" >> "$TEST_SUDO_TRACE"
[[ "${TEST_SUDO_FAIL:-0}" != 1 ]] || exit 13
chmod u+w "$TEST_SUDO_FIREFOX"
exec "$@"
SUDO
chmod +x "$TEST_DIR/recording-sudo/sudo"
chmod u-w "$case_firefox"
if [[ ! -w "$case_firefox" ]]; then
    PATH="$TEST_DIR/recording-sudo:$PATH" run_install
    # Source directories are random; validate staging before the first live rename.
    awk -v firefox="$case_firefox" '
        /^-m644$/ { if (!renaming) staged++ }
        /^mv$/ { if (!renaming && staged != 3) exit 1; renaming = 1 }
        END { if (!renaming) exit 1 }
    ' "$TEST_SUDO_TRACE" || fail 'sudo command arguments or ordering changed'
    cmp "$fixture/program/config.js" "$case_firefox/config.js" || fail 'sudo did not install startup file'
    make_case sudo-failure
    export TEST_SUDO_FIREFOX="$case_firefox" TEST_SUDO_PROFILE="$case_profile"
    chmod u-w "$case_firefox"
    if TEST_SUDO_FAIL=1 PATH="$TEST_DIR/recording-sudo:$PATH" run_install; then fail 'sudo failure reported success'; fi
    [[ ! -e "$case_profile/chrome" && ! -e "$case_firefox/config.js" ]] || fail 'sudo failure wrote files'
else
    echo 'sudo-path fixture skipped: current user can write mode-555 directories.'
fi
chmod u+w "$case_firefox"

# Interrupted receipt copies are recoverable before either startup file exists.
for receipt_state in empty truncated; do
    make_case "receipt-$receipt_state"
    if [[ "$receipt_state" == empty ]]; then
        touch "$case_firefox/.floating-urlbar-autoconfig"
    else
        printf 'partial ownership record' > "$case_firefox/.floating-urlbar-autoconfig"
    fi
    run_install
    run_uninstall --remove-shared-autoconfig --firefox-dir "$case_firefox"
    [[ ! -e "$case_firefox/config.js" && ! -e "$case_firefox/.floating-urlbar-autoconfig" ]] || fail "$receipt_state shared receipt was not recovered"
done

# Reinstall repairs receipts using upstream hashes, never local edits.
for receipt_state in missing empty truncated invalid duplicate wrong-hashes edited edited-module edited-complete; do
    make_case "profile-receipt-$receipt_state"
    run_install
    receipt="$case_profile/chrome/utils/.floating-urlbar-files"
    case "$receipt_state" in
        missing) rm "$receipt" ;;
        empty) : > "$receipt" ;;
        truncated|edited|edited-module) head -n 6 "$receipt" > "$TEST_DIR/partial"; cp "$TEST_DIR/partial" "$receipt" ;;
        invalid) printf 'invalid receipt' > "$receipt" ;;
        duplicate) head -n 1 "$receipt" >> "$receipt" ;;
        wrong-hashes) awk '{ printf "%064d %s\n", 0, $2 }' "$receipt" > "$TEST_DIR/partial"; cp "$TEST_DIR/partial" "$receipt" ;;
    esac
    edited_file=boot.sys.mjs
    if [[ "$receipt_state" == edited-module ]]; then edited_file=fs.sys.mjs; fi
    if [[ "$receipt_state" == edited* ]]; then printf 'preserve local edit\n' > "$case_profile/chrome/utils/$edited_file"; fi
    run_install
    [[ "$(wc -l < "$receipt" | tr -d ' ')" == 8 ]] || fail "$receipt_state profile receipt was not repaired"
    if [[ "$receipt_state" == edited* ]]; then
        if run_uninstall --remove-autoconfig; then fail 'receipt repair claimed local edit'; fi
        if run_uninstall --remove-shared-autoconfig --firefox-dir "$case_firefox"; then fail 'receipt repair bypassed shared cleanup safeguards'; fi
        [[ "$(cat "$case_profile/chrome/utils/$edited_file")" == 'preserve local edit' ]] || fail 'receipt repair lost local edit'
        [[ -f "$case_firefox/config.js" ]] || fail 'receipt repair allowed partial shared cleanup'
    else
        run_uninstall --remove-autoconfig
    fi
done

# Failed receipt repair leaves the current installation and damaged receipt intact.
make_case receipt-offline
run_install
printf 'damaged receipt\n' > "$case_profile/chrome/utils/.floating-urlbar-files"
cp -R "$case_profile" "$TEST_DIR/offline-before"
if TEST_AUTOCONFIG_DOWNLOAD_FAIL=1 run_install; then fail 'offline receipt repair succeeded'; fi
diff -r "$TEST_DIR/offline-before" "$case_profile" || fail 'offline receipt repair changed profile files'

for receipt_state in missing invalid incomplete; do
    make_case "shared-recovery-$receipt_state"
    run_install
    receipt="$case_firefox/.floating-urlbar-autoconfig"
    case "$receipt_state" in
        missing) rm "$receipt" ;;
        invalid) printf 'damaged receipt\n' > "$receipt" ;;
        incomplete) head -n 1 "$receipt" > "$TEST_DIR/partial"; cp "$TEST_DIR/partial" "$receipt" ;;
    esac
    if run_uninstall --remove-shared-autoconfig --firefox-dir "$case_firefox"; then fail 'cleanup accepted damaged shared receipt'; fi
    grep -q 'Shared startup ownership cannot be restored by reinstalling' "$TEST_DIR/uninstall.log" || fail 'shared recovery message suggested reinstall'
    [[ -f "$case_firefox/config.js" && -f "$case_profile/chrome/utils/boot.sys.mjs" ]] || fail 'shared receipt failure partially removed loader'
done

# Receipt repair can leave notice backups; uninstall/reinstall must keep them.
make_case receipt-backup-cycle
run_install
printf 'preserve edited notice\n' > "$case_profile/chrome/utils/fx-autoconfig.txt"
printf 'damaged receipt\n' > "$case_profile/chrome/utils/.floating-urlbar-files"
run_install
notice_backups=("$case_profile/chrome/utils/fx-autoconfig.txt.bak-"*)
[[ ${#notice_backups[@]} == 1 && "$(cat "${notice_backups[0]}")" == 'preserve edited notice' ]] || fail 'receipt repair lost edited notice'
run_uninstall --remove-autoconfig
run_install
[[ "$(cat "${notice_backups[0]}")" == 'preserve edited notice' ]] || fail 'reinstall changed notice backup'

# Empty cleanup is successful; untouched backup directories must also survive.
make_case cleanup-never-installed
mkdir -p "$case_profile/chrome"
printf 'unrelated native style\n' > "$case_profile/chrome/other.css"
run_uninstall --remove-autoconfig
run_uninstall --remove-shared-autoconfig --firefox-dir "$case_firefox"
rm "$case_profile/chrome/other.css"
run_install
mkdir -p "$case_profile/chrome/assets.css" "$case_profile/chrome/utils/module.bak-old"
run_uninstall --remove-shared-autoconfig --firefox-dir "$case_firefox"
run_uninstall --remove-autoconfig
run_uninstall --remove-shared-autoconfig --firefox-dir "$case_firefox"
[[ -d "$case_profile/chrome/assets.css" && -d "$case_profile/chrome/utils/module.bak-old" ]] || fail 'cleanup removed untouched directories'

# A PTY reaches the real interactive branches, including read failure (Ctrl+D).
if command -v python3 >/dev/null 2>&1; then
    python3 - "$TEST_DIR/checkout" "$TEST_DIR" <<'PY'
import os
from pathlib import Path
import pty
import subprocess
import sys

checkout, root = map(Path, sys.argv[1:])
for index, (answers, profile_removed, shared_removed) in enumerate([
    (b'\n', False, False), (b'invalid\n', False, False),
    (b'no\n', False, False), (b'yes\nno\n', True, False),
    (b'Y\nYES\n', True, True), (b'\x04', False, False),
]):
    profile, firefox = root / f'prompt-{index}/profile', root / f'prompt-{index}/Firefox'
    profile.mkdir(parents=True)
    firefox.mkdir()
    (profile / 'prefs.js').write_text('preserve preferences\n')
    (firefox / 'application.ini').write_text('[App]\n')
    (firefox / 'firefox').write_text('#!/bin/sh\nexit 0\n')
    (firefox / 'firefox').chmod(0o755)
    subprocess.run(['bash', str(checkout / 'install.sh'), '--profile', str(profile), '--firefox-dir', str(firefox)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    master, slave = pty.openpty()
    try:
        process = subprocess.Popen(['bash', str(checkout / 'uninstall.sh'), '--profile', str(profile), '--firefox-dir', str(firefox)], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        os.close(slave)
        os.write(master, answers)
        try:
            output = process.communicate(timeout=20)[0].decode()
        except subprocess.TimeoutExpired:
            process.kill()
            raise AssertionError(f'cleanup prompt hung for {answers!r}: {process.communicate()[0]!r}')
    finally:
        os.close(master)
    assert process.returncode == 0 and 'Uninstalled. Reopen Firefox' in output, output
    assert 'Also remove fx-autoconfig' in output, output
    assert (profile / 'chrome/utils/boot.sys.mjs').exists() != profile_removed, output
    assert (firefox / 'config.js').exists() != shared_removed, output
    assert not (profile / 'chrome/JS/replace-new-tab.uc.js').exists(), output
PY
else
    echo 'SKIP: interactive cleanup regressions require Python 3 for a PTY.'
fi

# Optional loader refusal must not undo housekeeping for removed payloads.
make_case cleanup-housekeeping
run_install
rm "$case_profile/chrome/utils/.floating-urlbar-source"
mkdir "$case_profile/startupCache"
printf 'cached payload\n' > "$case_profile/startupCache/fixture"
if TEST_FIREFOX_RUNNING=1 run_uninstall --remove-autoconfig; then fail 'unowned loader cleanup succeeded'; fi
[[ ! -e "$case_profile/chrome/JS/replace-new-tab.uc.js" && ! -e "$case_profile/chrome/CSS/firefox-floating-urlbar.uc.css" ]] || fail 'cleanup refusal left payloads'
[[ ! -e "$XDG_CONFIG_HOME/firefox-floating-urlbar/profile" && ! -e "$case_profile/startupCache" ]] || fail 'cleanup refusal skipped uninstall housekeeping'
[[ -f "$case_profile/chrome/utils/boot.sys.mjs" && -f "$case_firefox/config.js" ]] || fail 'cleanup refusal removed unowned loader'

for cleanup in keep profile shared edited other-script other-uc-mjs other-sys-mjs other-style linked-native other-utils external shared-edited shared-unowned malformed linked hardlinked; do
    make_case "cleanup-$cleanup"
    if [[ "$cleanup" == shared-unowned ]]; then
        mkdir -p "$case_firefox/defaults/pref"
        cp "$fixture/program/config.js" "$case_firefox/config.js"
        cp "$fixture/program/defaults/pref/config-prefs.js" "$case_firefox/defaults/pref/config-prefs.js"
    fi
    run_install
    case "$cleanup" in
        keep)
            run_uninstall
            [[ -f "$case_profile/chrome/utils/boot.sys.mjs" && -f "$case_firefox/config.js" ]] || fail 'default uninstall removed loader'
            ;;
        profile)
            run_uninstall --remove-autoconfig
            [[ ! -e "$case_profile/chrome/utils" && -f "$case_firefox/config.js" ]] || fail 'profile-only cleanup changed shared files or left loader'
            ;;
        shared)
            run_uninstall --remove-shared-autoconfig --firefox-dir "$case_firefox"
            [[ ! -e "$case_profile/chrome/utils" && ! -e "$case_firefox/config.js" && ! -e "$case_firefox/defaults/pref/config-prefs.js" && ! -e "$case_firefox/.floating-urlbar-autoconfig" ]] || fail 'full cleanup left owned files'
            ;;
        *)
            case "$cleanup" in
                edited) printf 'local loader edit\n' > "$case_profile/chrome/utils/boot.sys.mjs" ;;
                other-script) printf 'other script\n' > "$case_profile/chrome/JS/other.uc.js" ;;
                other-uc-mjs) printf 'other module\n' > "$case_profile/chrome/JS/other.uc.mjs" ;;
                other-sys-mjs) printf 'other module\n' > "$case_profile/chrome/JS/other.sys.mjs" ;;
                other-style) printf 'nested style\n' > "$case_profile/chrome/CSS/userChrome.css" ;;
                linked-native) ln -s "$fixture/program/config.js" "$case_profile/chrome/userChrome.css" ;;
                other-utils) printf 'other module\n' > "$case_profile/chrome/utils/other.sys.mjs" ;;
                external) rm "$case_profile/chrome/utils/.floating-urlbar-source" ;;
                shared-edited) printf 'shared edit\n' > "$case_firefox/config.js" ;;
                malformed) printf '%064d ../prefs.js\n' 0 > "$case_profile/chrome/utils/.floating-urlbar-files" ;;
                linked) rm "$case_profile/chrome/utils/boot.sys.mjs"; ln -s "$fixture/profile/chrome/utils/boot.sys.mjs" "$case_profile/chrome/utils/boot.sys.mjs" ;;
                hardlinked) rm "$case_profile/chrome/utils/boot.sys.mjs"; ln "$fixture/profile/chrome/utils/boot.sys.mjs" "$case_profile/chrome/utils/boot.sys.mjs" ;;
            esac
            if [[ "$cleanup" == other-*-mjs ]]; then
                if run_uninstall --remove-autoconfig; then fail "unsafe $cleanup profile cleanup succeeded"; fi
            fi
            if run_uninstall --remove-shared-autoconfig --firefox-dir "$case_firefox"; then fail "unsafe $cleanup cleanup succeeded"; fi
            [[ -e "$case_profile/chrome/utils/chrome.manifest" && -e "$case_firefox/config.js" ]] || fail "$cleanup cleanup partially removed loader"
            ;;
    esac
    [[ "$(cat "$case_profile/prefs.js")" == 'unchanged prefs' ]] || fail "$cleanup cleanup changed prefs"
done

for cleanup in delayed delayed-backup delayed-edited delayed-unowned missing-chrome native-styles windows-receipt metadata; do
    make_case "cleanup-$cleanup"
    # Brackets must not be treated as find patterns when excluding native files.
    mv "$case_profile" "$case_profile [2024]"
    case_profile="$case_profile [2024]"
    run_install
    case "$cleanup" in
        metadata)
            for file in .DS_Store Thumbs.db desktop.ini; do printf 'metadata\n' > "$case_profile/chrome/utils/$file"; done
            ;;
        missing-chrome) rm -rf -- "$case_profile/chrome" ;;
        delayed*)
            if [[ "$cleanup" == delayed-backup ]]; then
                printf 'preserve backup\n' > "$case_profile/chrome/utils/boot.sys.mjs.bak-old"
            fi
            run_uninstall --remove-autoconfig
            [[ ! -e "$case_profile/chrome/utils/boot.sys.mjs" && -f "$case_firefox/config.js" ]] || fail 'first cleanup did not leave shared files'
            if [[ "$cleanup" == delayed-edited ]]; then
                printf 'local startup edit\n' > "$case_firefox/config.js"
            elif [[ "$cleanup" == delayed-unowned ]]; then
                mkdir -p "$case_profile/chrome/utils"
                printf 'external loader\n' > "$case_profile/chrome/utils/boot.sys.mjs"
            fi
            ;;
        native-styles)
            printf 'native chrome style\n' > "$case_profile/chrome/userChrome.css"
            printf 'native content style\n' > "$case_profile/chrome/userContent.css"
            ;;
        windows-receipt)
            for receipt in "$case_profile/chrome/utils/.floating-urlbar-files" "$case_firefox/.floating-urlbar-autoconfig"; do
                awk '{ printf "%s %s\r\n", toupper($1), $2 }' "$receipt" > "$TEST_DIR/windows-receipt"
                cp "$TEST_DIR/windows-receipt" "$receipt"
            done
            ;;
    esac
    if [[ "$cleanup" == delayed-edited || "$cleanup" == delayed-unowned ]]; then
        if run_uninstall --remove-shared-autoconfig --firefox-dir "$case_firefox"; then fail "unsafe $cleanup succeeded"; fi
        [[ -f "$case_firefox/config.js" && -f "$case_firefox/defaults/pref/config-prefs.js" && -f "$case_firefox/.floating-urlbar-autoconfig" ]] || fail "$cleanup removed shared files"
        if [[ "$cleanup" == delayed-unowned ]]; then
            [[ "$(cat "$case_profile/chrome/utils/boot.sys.mjs")" == 'external loader' ]] || fail 'delayed cleanup removed unowned loader'
        fi
        continue
    fi
    run_uninstall --remove-shared-autoconfig --firefox-dir "$case_firefox"
    [[ ! -e "$case_profile/chrome/utils/boot.sys.mjs" && ! -e "$case_firefox/config.js" && ! -e "$case_firefox/.floating-urlbar-autoconfig" ]] || fail "$cleanup left owned files"
    if [[ "$cleanup" == delayed-backup ]]; then
        [[ "$(cat "$case_profile/chrome/utils/boot.sys.mjs.bak-old")" == 'preserve backup' ]] || fail 'delayed cleanup lost backup'
    elif [[ "$cleanup" == native-styles ]]; then
        [[ "$(cat "$case_profile/chrome/userChrome.css")" == 'native chrome style' && "$(cat "$case_profile/chrome/userContent.css")" == 'native content style' ]] || fail 'cleanup changed native styles'
    elif [[ "$cleanup" == metadata ]]; then
        for file in .DS_Store Thumbs.db desktop.ini; do [[ "$(cat "$case_profile/chrome/utils/$file")" == metadata ]] || fail 'cleanup removed metadata'; done
    fi
done

# The shared-removal elevation branch is isolated from all profile writes.
for outcome in success failure; do
    make_case "cleanup-sudo-$outcome"
    run_install
    chmod u-w "$case_firefox" "$case_firefox/defaults/pref"
    if [[ ! -w "$case_firefox" ]]; then
        (
            source "$TEST_DIR/checkout/lib.sh"
            source "$TEST_DIR/checkout/autoconfig.sh"
            # Our payloads have already been removed by the uninstall entry point.
            rm "$case_profile/chrome/JS/replace-new-tab.uc.js" "$case_profile/chrome/CSS/firefox-floating-urlbar.uc.css"
            sudo() {
                [[ -f "$case_profile/chrome/utils/boot.sys.mjs" ]] || fail 'profile removed before elevation finished'
                [[ "$*" == "rm -f -- $case_firefox/"* ]] || fail 'unexpected privileged cleanup command'
                [[ "$outcome" == success ]] || return 13
                chmod u+w "$case_firefox" "$case_firefox/defaults/pref"
                "$@"
            }
            if [[ "$outcome" == success ]]; then
                remove_autoconfig "$case_profile" "$case_firefox" 1
                [[ ! -e "$case_profile/chrome/utils" && ! -e "$case_firefox/config.js" ]] || fail 'sudo cleanup left owned files'
            else
                if remove_autoconfig "$case_profile" "$case_firefox" 1; then fail 'sudo cleanup failure reported success'; fi
                [[ -f "$case_profile/chrome/utils/boot.sys.mjs" && -f "$case_firefox/config.js" ]] || fail 'sudo cleanup failure removed loader'
            fi
        ) > "$TEST_DIR/cleanup-sudo.log" 2>&1
    fi
    chmod u+w "$case_firefox" "$case_firefox/defaults/pref"
done

# Continue the original upgrade checks on a fresh managed installation.
for legacy in unchanged edited; do
    make_case "legacy-$legacy"
    run_install
    rm "$case_profile/chrome/utils/.floating-urlbar-files" "$case_firefox/.floating-urlbar-autoconfig"
    if [[ "$legacy" == edited ]]; then printf 'legacy local edit\n' > "$case_profile/chrome/utils/boot.sys.mjs"; fi
    run_install
    [[ -f "$case_profile/chrome/utils/.floating-urlbar-files" && ! -e "$case_firefox/.floating-urlbar-autoconfig" ]] || fail 'legacy migration claimed shared files or missed profile receipt'
    if [[ "$legacy" == unchanged ]]; then
        run_uninstall --remove-autoconfig
        [[ ! -e "$case_profile/chrome/utils" && -f "$case_firefox/config.js" ]] || fail 'legacy profile cleanup failed'
    else
        if run_uninstall --remove-autoconfig; then fail 'legacy migration claimed local edits'; fi
        [[ "$(cat "$case_profile/chrome/utils/boot.sys.mjs")" == 'legacy local edit' ]] || fail 'legacy local edit lost'
    fi
done

make_case upgrade
run_install
downloads_before="$(wc -l < "$TEST_DOWNLOAD_TRACE")"

# An upgrade of our loader keeps a backup; third-party loaders remain untouched.
printf 'older\n' > "$case_profile/chrome/utils/.floating-urlbar-source"
printf 'local module edit\n' > "$case_profile/chrome/utils/boot.sys.mjs"
run_install
backups=("$case_profile/chrome/utils/boot.sys.mjs.bak-"*)
[[ ${#backups[@]} == 1 && "$(cat "${backups[0]}")" == 'local module edit' ]] || fail 'loader upgrade lost modified module'
metadata_backups=("$case_profile/chrome/utils/.floating-urlbar-"*.bak-*)
[[ ! -e "${metadata_backups[0]}" ]] || fail 'loader upgrade left metadata backups'
rm "$case_profile/chrome/utils/.floating-urlbar-source"
printf 'third-party loader\n' > "$case_profile/chrome/utils/boot.sys.mjs"
run_install
[[ "$(cat "$case_profile/chrome/utils/boot.sys.mjs")" == 'third-party loader' ]] || fail 'replaced existing loader'
(( $(wc -l < "$TEST_DOWNLOAD_TRACE") == downloads_before + 1 )) || fail 'existing loader triggered download'

# Existing loaders are preserved, with a warning if standard startup files are missing.
for startup in config.js defaults/pref/config-prefs.js; do
    rm "$case_firefox/$startup"
    run_install
    grep -q 'standard AutoConfig startup files are missing' "$TEST_DIR/install.log" ||
        fail 'existing loader with missing startup file did not warn'
    [[ ! -e "$case_firefox/$startup" ]] || fail 'changed externally managed startup configuration'
    [[ "$(cat "$case_profile/chrome/utils/boot.sys.mjs")" == 'third-party loader' ]] || fail 'changed external loader during startup check'
    (( $(wc -l < "$TEST_DOWNLOAD_TRACE") == downloads_before + 1 )) || fail 'external loader startup check triggered download'
    cp "$fixture/program/$startup" "$case_firefox/$startup"
done

# A current managed loader still needs its program-side startup files.
make_case repair-startup
run_install
printf 'preserve local loader edit\n' > "$case_profile/chrome/utils/boot.sys.mjs"
for startup in config.js defaults/pref/config-prefs.js; do
    downloads_before="$(wc -l < "$TEST_DOWNLOAD_TRACE")"
    rm "$case_firefox/$startup"
    run_install
    cmp "$fixture/program/$startup" "$case_firefox/$startup" || fail "did not restore managed $startup"
    [[ "$(cat "$case_profile/chrome/utils/boot.sys.mjs")" == 'preserve local loader edit' ]] || fail 'startup repair overwrote profile loader'
    (( $(wc -l < "$TEST_DOWNLOAD_TRACE") == downloads_before + 1 )) || fail 'startup repair did not fetch verified source'
done
# Missing notices are repaired without replacing a locally edited loader.
for notice in fx-autoconfig.LICENSE fx-autoconfig.txt; do
    rm "$case_profile/chrome/utils/$notice"
    run_install
    [[ -f "$case_profile/chrome/utils/$notice" ]] || fail "did not restore $notice"
    [[ "$(cat "$case_profile/chrome/utils/boot.sys.mjs")" == 'preserve local loader edit' ]] || fail 'notice repair changed profile loader'
done
downloads_before="$(wc -l < "$TEST_DOWNLOAD_TRACE")"
run_install
(( $(wc -l < "$TEST_DOWNLOAD_TRACE") == downloads_before + 1 )) || fail 'edited loader did not trigger receipt verification'
[[ "$(cat "$case_profile/chrome/utils/boot.sys.mjs")" == 'preserve local loader edit' ]] || fail 'receipt verification changed edited loader'
[[ "$(cat "$case_profile/prefs.js")" == 'unchanged prefs' ]] || fail 'startup repair changed prefs'

# Repair keeps the same checksum and conflict protections as first-time setup.
rm "$case_firefox/config.js"
original_archive="$TEST_AUTOCONFIG_ARCHIVE"
printf 'corrupt repair download' > "$TEST_DIR/bad-repair.tar.gz"
export TEST_AUTOCONFIG_ARCHIVE="$TEST_DIR/bad-repair.tar.gz"
if run_install; then fail 'startup repair accepted corrupt archive'; fi
[[ ! -e "$case_firefox/config.js" ]] || fail 'failed verification wrote startup file'
export TEST_AUTOCONFIG_ARCHIVE="$original_archive"
printf 'preserve startup configuration\n' > "$case_firefox/defaults/pref/config-prefs.js"
if run_install; then fail 'startup repair accepted conflicting configuration'; fi
[[ ! -e "$case_firefox/config.js" ]] || fail 'startup repair wrote files despite conflict'
[[ "$(cat "$case_firefox/defaults/pref/config-prefs.js")" == 'preserve startup configuration' ]] || fail 'startup repair changed conflicting configuration'
[[ "$(cat "$case_profile/chrome/utils/boot.sys.mjs")" == 'preserve local loader edit' ]] || fail 'failed startup repair changed profile loader'

# A failed staging copy leaves no live loader, and retry installs the whole set.
make_case interrupted-loader
mkdir "$TEST_DIR/failing-module-copy"
export TEST_REAL_CP
TEST_REAL_CP="$(command -v cp)"
cat > "$TEST_DIR/failing-module-copy/cp" <<'CP'
#!/usr/bin/env bash
if [[ "${*: -1}" == */fs.sys.mjs ]]; then exit 1; fi
exec "$TEST_REAL_CP" "$@"
CP
chmod +x "$TEST_DIR/failing-module-copy/cp"
if PATH="$TEST_DIR/failing-module-copy:$PATH" run_install; then fail 'partial loader copy reported success'; fi
[[ ! -e "$case_profile/chrome/utils/boot.sys.mjs" && ! -e "$case_firefox/config.js" ]] || fail 'failed staging wrote live loader files'
run_install
for module in boot.sys.mjs fs.sys.mjs utils.sys.mjs uc_api.sys.mjs module_loader.mjs; do
    cmp "$fixture/profile/chrome/utils/$module" "$case_profile/chrome/utils/$module" || fail "retry did not restore $module"
done
[[ "$(cat "$case_profile/chrome/utils/.floating-urlbar-source")" == fixture ]] || fail 'retry did not finalize loader ownership'

# An interrupted first replacement must not be mistaken for an external loader.
make_case interrupted-replacement
mkdir "$TEST_DIR/interrupted-replacement-bin"
cat > "$TEST_DIR/interrupted-replacement-bin/mv" <<'MV'
#!/usr/bin/env bash
if [[ "${@: -2:1}" == */.floating-urlbar-install.*/utils/fs.sys.mjs ]]; then
    kill -TERM "$PPID"
    exit 143
fi
exec "$TEST_STARTUP_REAL_MV" "$@"
MV
chmod +x "$TEST_DIR/interrupted-replacement-bin/mv"
if PATH="$TEST_DIR/interrupted-replacement-bin:$PATH" run_install; then fail 'interrupted replacement reported success'; fi
[[ -f "$case_profile/chrome/utils/boot.sys.mjs" && ! -e "$case_profile/chrome/utils/fs.sys.mjs" ]] || fail 'interruption fixture did not reach partial replacement'
[[ "$(cat "$case_profile/chrome/utils/.floating-urlbar-source")" == pending* ]] || fail 'interruption lost pending ownership'
run_install
cmp "$fixture/profile/chrome/utils/fs.sys.mjs" "$case_profile/chrome/utils/fs.sys.mjs" || fail 'interrupted replacement was mistaken for an external loader'
[[ "$(cat "$case_profile/chrome/utils/.floating-urlbar-source")" == fixture ]] || fail 'interrupted replacement retry did not finish'

make_case checksum
original_archive="$TEST_AUTOCONFIG_ARCHIVE"
printf 'corrupt download' > "$TEST_DIR/bad.tar.gz"
export TEST_AUTOCONFIG_ARCHIVE="$TEST_DIR/bad.tar.gz"
if run_install; then fail 'accepted corrupt archive'; fi
[[ ! -e "$case_firefox/config.js" && ! -e "$case_profile/chrome" ]] || fail 'checksum failure wrote files'
export TEST_AUTOCONFIG_ARCHIVE="$original_archive"

make_case failed-copy
mkdir "$TEST_DIR/failing-install"
export TEST_REAL_INSTALL
TEST_REAL_INSTALL="$(command -v install)"
cat > "$TEST_DIR/failing-install/install" <<'INSTALL'
#!/usr/bin/env bash
if [[ "${*: -1}" == */.floating-urlbar-startup.*/new-0 ]]; then exit 1; fi
exec "$TEST_REAL_INSTALL" "$@"
INSTALL
chmod +x "$TEST_DIR/failing-install/install"
if PATH="$TEST_DIR/failing-install:$PATH" run_install; then fail 'startup copy failure reported success'; fi
[[ ! -e "$case_firefox/defaults/pref/config-prefs.js" ]] || fail 'activated AutoConfig after config.js copy failed'
[[ ! -e "$case_profile/chrome" ]] || fail 'startup copy failure installed profile files'

for kind in custom-config custom-prefs linked-config linked-utils; do
    make_case "$kind"
    outside="$TEST_DIR/$kind/outside"
    printf 'preserve user configuration\n' > "$outside"
    case "$kind" in
        custom-config) cp "$outside" "$case_firefox/config.js" ;;
        custom-prefs)
            mkdir -p "$case_firefox/defaults/pref"
            printf 'pref("general.config.filename", "other.cfg");\n' > "$case_firefox/defaults/pref/custom.js" ;;
        linked-config) ln -s "$outside" "$case_firefox/config.js" ;;
        linked-utils)
            mkdir -p "$case_profile/chrome"
            ln -s "$TEST_DIR/$kind" "$case_profile/chrome/utils" ;;
    esac
    if run_install; then fail "accepted $kind"; fi
    [[ "$(cat "$outside")" == 'preserve user configuration' ]] || fail "$kind changed outside data"
    [[ ! -e "$case_profile/chrome/JS/replace-new-tab.uc.js" ]] || fail "$kind partially installed payload"
    [[ ! -e "$case_firefox/defaults/pref/config-prefs.js" ]] || fail "$kind activated AutoConfig"
done

# Package-managed modules are linked without downloading or writing startup files.
make_case packaged
mkdir -p "$case_firefox/defaults/pref"
printf '// package startup\n' > "$case_firefox/config.js"
printf 'pref("general.config.filename", "config.js");\n' > "$case_firefox/defaults/pref/config-prefs.js"
(
    # shellcheck source=../lib.sh
    source "$TEST_DIR/checkout/lib.sh"
    # shellcheck source=../autoconfig.sh
    source "$TEST_DIR/checkout/autoconfig.sh"
    packaged_autoconfig_directory() { printf '%s\n' "$fixture/profile/chrome/utils"; }
    ensure_autoconfig "$case_profile" "$case_firefox"
) > "$TEST_DIR/packaged.log" 2>&1
[[ -L "$case_profile/chrome/utils/boot.sys.mjs" ]] || fail 'packaged loader was copied instead of linked'
[[ ! -e "$case_profile/chrome/utils/.floating-urlbar-source" ]] || fail 'package setup wrote unmanaged marker'

# Reusing a package-backed loader must not skip startup-file checks.
for startup in config.js defaults/pref/config-prefs.js; do
    rm "$case_firefox/$startup"
    if (
        source "$TEST_DIR/checkout/lib.sh"
        source "$TEST_DIR/checkout/autoconfig.sh"
        # Keep the fixture link readable while emulating the package's target.
        readlink() {
            if [[ "$1" == "$case_profile/chrome/utils/boot.sys.mjs" ]]; then
                printf '%s\n' /usr/share/fx-autoconfig/utils/boot.sys.mjs
            else command readlink "$@"; fi
        }
        ensure_autoconfig "$case_profile" "$case_firefox"
    ) > "$TEST_DIR/packaged-reuse.log" 2>&1; then fail "packaged reuse accepted missing $startup"; fi
    grep -q 'Reinstall the fx-autoconfig package' "$TEST_DIR/packaged-reuse.log" ||
        fail 'packaged reuse did not explain how to repair startup files'
    cp "$fixture/program/$startup" "$case_firefox/$startup"
done

# Failed package conversion restores every old module and its ownership marker.
for failure in link rename finalize; do
    make_case "packaged-failed-$failure"
    mkdir -p "$case_firefox/defaults/pref" "$case_profile/chrome/utils"
    cp "$fixture/program/config.js" "$case_firefox/config.js"
    cp "$fixture/program/defaults/pref/config-prefs.js" "$case_firefox/defaults/pref/config-prefs.js"
    printf 'older\n' > "$case_profile/chrome/utils/.floating-urlbar-source"
    for file in chrome.manifest boot.sys.mjs fs.sys.mjs utils.sys.mjs uc_api.sys.mjs module_loader.mjs; do
        printf 'old %s\n' "$file" > "$case_profile/chrome/utils/$file"
    done
    cp -R "$case_profile/chrome/utils" "$TEST_DIR/package-before-$failure"
    if (
        source "$TEST_DIR/checkout/lib.sh"
        source "$TEST_DIR/checkout/autoconfig.sh"
        packaged_autoconfig_directory() { printf '%s\n' "$fixture/profile/chrome/utils"; }
        case "$failure" in
            link) ln() { [[ "${*: -1}" != */fs.sys.mjs ]] || return 1; command ln "$@"; } ;;
            rename) mv() { [[ "${@: -2:1}" != */utils/fs.sys.mjs ]] || return 1; command mv "$@"; } ;;
            finalize) rm() { [[ "${*: -1}" != "$case_profile/chrome/utils/.floating-urlbar-source" ]] || return 1; command rm "$@"; } ;;
        esac
        ensure_autoconfig "$case_profile" "$case_firefox"
    ) > "$TEST_DIR/packaged-failed-$failure.log" 2>&1; then fail "package $failure failure accepted"; fi
    for file in "$TEST_DIR/package-before-$failure/"* "$TEST_DIR/package-before-$failure/.floating-urlbar-source"; do
        [[ ! -L "$case_profile/chrome/utils/${file##*/}" ]] || fail "package $failure left a new link"
        cmp "$file" "$case_profile/chrome/utils/${file##*/}" || fail "package $failure lost ${file##*/}"
    done
    [[ -z "$(find "$case_profile/chrome" -name '.floating-urlbar-links.*' -o -name '.floating-urlbar-install.*')" ]] ||
        fail "package $failure failure left staging files"
done

# A package without its startup files must fail instead of reporting success.
make_case packaged-missing
if (
    source "$TEST_DIR/checkout/lib.sh"
    source "$TEST_DIR/checkout/autoconfig.sh"
    packaged_autoconfig_directory() { printf '%s\n' "$fixture/profile/chrome/utils"; }
    ensure_autoconfig "$case_profile" "$case_firefox"
) > "$TEST_DIR/packaged-missing.log" 2>&1; then fail 'packaged setup accepted missing startup files'; fi

# A folder with a firefox executable but no application.ini is a wrapper
# directory (e.g. /usr/bin), never an install directory.
mkdir -p "$TEST_DIR/wrapperbin"
printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/wrapperbin/firefox"
chmod +x "$TEST_DIR/wrapperbin/firefox"
if (
    source "$TEST_DIR/checkout/lib.sh"
    source "$TEST_DIR/checkout/autoconfig.sh"
    find_firefox_directory "$case_profile" "$TEST_DIR/wrapperbin"
) > "$TEST_DIR/wrapperbin.log" 2>&1; then fail 'wrapper directory accepted as Firefox installation'; fi

# Exercise PATH discovery without --firefox-dir, including a wrapper executable.
(
    source "$TEST_DIR/checkout/lib.sh"
    source "$TEST_DIR/checkout/autoconfig.sh"
    export PATH="$TEST_DIR/wrapperbin:$PATH"
    if detected="$(find_firefox_directory "$case_profile" "" 2>/dev/null)"; then
        [[ "$detected" != "$TEST_DIR/wrapperbin" ]] || fail 'PATH fallback accepted a wrapper directory'
    fi
    mkdir -p "$TEST_DIR/pathbin"
    ln -s "$case_firefox/firefox" "$TEST_DIR/pathbin/firefox"
    printf '[Compatibility]\nLastPlatformDir=%s\n' "$TEST_DIR/wrapperbin" > "$case_profile/compatibility.ini"
    export PATH="$TEST_DIR/pathbin:$PATH"
    [[ "$(find_firefox_directory "$case_profile" "")" == "$case_firefox" ]] ||
        fail 'PATH fallback did not find the real installation after a stale profile hint'
)

# Exercise the resource-directory layout everywhere, using native BSD stat on macOS.
mkdir -p "$TEST_DIR/Firefox.app/Contents/Resources" "$TEST_DIR/Firefox.app/Contents/MacOS"
cp "$case_firefox/firefox" "$TEST_DIR/Firefox.app/Contents/MacOS/firefox"
printf '[App]\n' > "$TEST_DIR/Firefox.app/Contents/Resources/application.ini"
(
    source "$REPO_DIR/lib.sh"
    source "$REPO_DIR/autoconfig.sh"
    [[ "$(find_firefox_directory "$case_profile" "$TEST_DIR/Firefox.app/Contents/Resources")" == "$TEST_DIR/Firefox.app/Contents/Resources" ]] || fail 'macOS resource directory detection'
    if [[ "$(uname -s)" != Darwin ]]; then
        uname() { printf 'Darwin\n'; }
        stat() { [[ "$1 $2" == '-f %l' ]] || fail 'wrong BSD stat flags'; command stat -c %h "$3"; }
    fi
    require_file_destination "$case_profile/prefs.js"
    ln "$case_profile/prefs.js" "$TEST_DIR/hardlinked-prefs"
    if (require_file_destination "$TEST_DIR/hardlinked-prefs") >/dev/null 2>&1; then fail 'BSD hardlink guard failed'; fi
)
echo 'AutoConfig regressions passed (offline fixtures, temporary installations, mocked package detection).'

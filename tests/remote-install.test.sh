#!/usr/bin/env bash
# Offline test for install-remote.sh: a stubbed curl serves a fixture repo
# archive. Stub installers check forwarding; real installers check downloaded inputs.
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
TEST_DIR="$(cd -- "$TEST_DIR" && pwd -P)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TEST_DIR/fixture/firefox-floating-urlbar-main" "$TEST_DIR/bin" "$TEST_DIR/tmp"
cat > "$TEST_DIR/fixture/firefox-floating-urlbar-main/install.sh" <<'INSTALL'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_INSTALL_TRACE"
exit "${TEST_INSTALL_EXIT:-0}"
INSTALL
cat > "$TEST_DIR/fixture/firefox-floating-urlbar-main/uninstall.sh" <<'UNINSTALL'
#!/usr/bin/env bash
printf '%s\n' uninstall "$@" > "$TEST_INSTALL_TRACE"
exit "${TEST_INSTALL_EXIT:-0}"
UNINSTALL
chmod +x "$TEST_DIR/fixture/firefox-floating-urlbar-main/install.sh"
tar -czf "$TEST_DIR/repo.tar.gz" -C "$TEST_DIR/fixture" firefox-floating-urlbar-main
cat > "$TEST_DIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${TEST_CURL_FAIL:-}" ]]; then exit "$TEST_CURL_FAIL"; fi
output="" url="${*: -1}"
while (( $# )); do
    if [[ "$1" == --output ]]; then output="$2"; shift; fi
    shift
done
if [[ "$url" == https://example.invalid/repo.tar.gz ]]; then
    cp "$TEST_FIXTURE_ARCHIVE" "$output"
elif [[ "$url" == https://codeload.github.com/constantinemagnus/firefox-floating-urlbar/tar.gz/refs/heads/main ]]; then
    printf '%s\n' "$url" >> "$TEST_DOWNLOAD_TRACE"
    cp "$TEST_DEFAULT_ARCHIVE" "$output"
elif [[ "$url" == https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.sh ]]; then
    printf '%s\n' 'printf "downloaded installer ran\n" > "$TEST_INITIAL_TRACE"'
else
    exit 1
fi
CURL
chmod +x "$TEST_DIR/bin/curl"
export PATH="$TEST_DIR/bin:$PATH" TMPDIR="$TEST_DIR/tmp"
export TEST_FIXTURE_ARCHIVE="$TEST_DIR/repo.tar.gz" TEST_INSTALL_TRACE="$TEST_DIR/install.trace"
export FIREFOX_FLOATING_URLBAR_URL='https://example.invalid/repo.tar.gz'

bash "$REPO_DIR/install-remote.sh" --profile '/temporary profile' --firefox-dir '/temporary Firefox'
[[ "$(cat "$TEST_INSTALL_TRACE")" == "$(printf '%s\n' --profile '/temporary profile' --firefox-dir '/temporary Firefox')" ]] ||
    fail 'remote installer did not forward arguments'
[[ -z "$(find "$TEST_DIR/tmp" -mindepth 1)" ]] || fail 'remote installer left temporary files'

bash "$REPO_DIR/install-remote.sh" --uninstall --profile '/temporary profile'
[[ "$(cat "$TEST_INSTALL_TRACE")" == "$(printf '%s\n' uninstall --profile '/temporary profile')" ]] ||
    fail 'remote installer did not route uninstall arguments'
[[ -z "$(find "$TEST_DIR/tmp" -mindepth 1)" ]] || fail 'remote uninstall left temporary files'

if TEST_INSTALL_EXIT=9 bash "$REPO_DIR/install-remote.sh" --uninstall; then
    fail 'remote installer swallowed child failure'
else
    [[ "$?" == 9 ]] || fail 'remote installer changed child failure status'
fi
[[ -z "$(find "$TEST_DIR/tmp" -mindepth 1)" ]] || fail 'failed remote uninstall left temporary files'

# An override archive must contain the selected installer, for either operation.
for installer in install.sh uninstall.sh; do
    mkdir -p "$TEST_DIR/manual/firefox-floating-urlbar-manual"
    printf 'manual archive\n' > "$TEST_DIR/manual/firefox-floating-urlbar-manual/README.md"
    tar -czf "$TEST_DIR/manual.tar.gz" -C "$TEST_DIR/manual" firefox-floating-urlbar-manual
    args=()
    if [[ "$installer" == uninstall.sh ]]; then args=(--uninstall); fi
    if TEST_FIXTURE_ARCHIVE="$TEST_DIR/manual.tar.gz" bash "$REPO_DIR/install-remote.sh" "${args[@]+"${args[@]}"}" > "$TEST_DIR/layout.log" 2>&1; then fail "accepted archive without $installer"; fi
    grep -q 'unexpected repository archive layout' "$TEST_DIR/layout.log" || fail "missing layout diagnostic for $installer"
    [[ -z "$(find "$TEST_DIR/tmp" -mindepth 1)" ]] || fail 'invalid layout left temporary files'
done

# Default mode downloads one archive of main; no GitHub API request is made.
unset FIREFOX_FLOATING_URLBAR_URL
export TEST_DEFAULT_ARCHIVE="$TEST_DIR/repo.tar.gz" TEST_DOWNLOAD_TRACE="$TEST_DIR/download.trace"
bash "$REPO_DIR/install-remote.sh" --uninstall --profile '/temporary profile'
[[ "$(cat "$TEST_INSTALL_TRACE")" == "$(printf '%s\n' uninstall --profile '/temporary profile')" ]] || fail 'default installer did not route arguments'
[[ "$(cat "$TEST_DOWNLOAD_TRACE")" == https://codeload.github.com/constantinemagnus/firefox-floating-urlbar/tar.gz/refs/heads/main ]] ||
    fail 'default installer downloaded unexpected URLs'
[[ -z "$(find "$TEST_DIR/tmp" -mindepth 1)" ]] || fail 'default installer left temporary files'

printf 'not an archive\n' > "$TEST_DIR/corrupt.tar.gz"
for failure in download corrupt-archive; do
    rm -f "$TEST_INSTALL_TRACE"
    status=0
    case "$failure" in
        download) TEST_CURL_FAIL=7 bash "$REPO_DIR/install-remote.sh" > "$TEST_DIR/failure.log" 2>&1 || status=$? ;;
        corrupt-archive) TEST_DEFAULT_ARCHIVE="$TEST_DIR/corrupt.tar.gz" bash "$REPO_DIR/install-remote.sh" > "$TEST_DIR/failure.log" 2>&1 || status=$? ;;
    esac
    [[ "$status" != 0 ]] || fail "accepted $failure"
    [[ ! -e "$TEST_INSTALL_TRACE" ]] || fail "ran installer after $failure"
    [[ -z "$(find "$TEST_DIR/tmp" -mindepth 1)" ]] || fail "$failure left temporary files"
done

# Serve the checkout's real installers through the same archive download path.
export XDG_CONFIG_HOME="$TEST_DIR/config"
real_source="$TEST_DIR/real-source/firefox-floating-urlbar-main"
mkdir -p "$real_source/JS" "$real_source/CSS" "$TEST_DIR/real-profile/chrome/utils" "$TEST_DIR/real-Firefox/defaults/pref"
cp "$REPO_DIR/"*.sh "$REPO_DIR/fx-autoconfig.conf" "$real_source/"
cp "$REPO_DIR/JS/replace-new-tab.uc.js" "$real_source/JS/"
cp "$REPO_DIR/CSS/firefox-floating-urlbar.uc.css" "$real_source/CSS/"
tar -czf "$TEST_DIR/real.tar.gz" -C "$TEST_DIR/real-source" firefox-floating-urlbar-main
export TEST_DEFAULT_ARCHIVE="$TEST_DIR/real.tar.gz"
printf '#!/bin/sh\nexit 1\n' > "$TEST_DIR/bin/pgrep"
chmod +x "$TEST_DIR/bin/pgrep"
printf 'initialized profile\n' > "$TEST_DIR/real-profile/prefs.js"
printf 'existing external loader\n' > "$TEST_DIR/real-profile/chrome/utils/boot.sys.mjs"
printf 'existing manifest\n' > "$TEST_DIR/real-profile/chrome/utils/chrome.manifest"
printf '[App]\n' > "$TEST_DIR/real-Firefox/application.ini"
printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/real-Firefox/firefox"
chmod +x "$TEST_DIR/real-Firefox/firefox"
printf '// existing startup\n' > "$TEST_DIR/real-Firefox/config.js"
printf '// existing preferences\n' > "$TEST_DIR/real-Firefox/defaults/pref/config-prefs.js"
bash "$REPO_DIR/install-remote.sh" --profile "$TEST_DIR/real-profile" --firefox-dir "$TEST_DIR/real-Firefox" > "$TEST_DIR/real-install.log" 2>&1 || {
    cat "$TEST_DIR/real-install.log"; fail 'real downloaded installer failed';
}
cmp "$REPO_DIR/JS/replace-new-tab.uc.js" "$TEST_DIR/real-profile/chrome/JS/replace-new-tab.uc.js" || fail 'real remote install missed JavaScript'
cmp "$REPO_DIR/CSS/firefox-floating-urlbar.uc.css" "$TEST_DIR/real-profile/chrome/CSS/firefox-floating-urlbar.uc.css" || fail 'real remote install missed stylesheet'
[[ -f "$XDG_CONFIG_HOME/firefox-floating-urlbar/profile" ]] || fail 'real remote install missed saved state'
bash "$REPO_DIR/install-remote.sh" --uninstall --profile "$TEST_DIR/real-profile" > "$TEST_DIR/real-uninstall.log" 2>&1 || {
    cat "$TEST_DIR/real-uninstall.log"; fail 'real downloaded uninstaller failed';
}
[[ ! -e "$TEST_DIR/real-profile/chrome/JS/replace-new-tab.uc.js" && ! -e "$TEST_DIR/real-profile/chrome/CSS/firefox-floating-urlbar.uc.css" ]] || fail 'real remote uninstall left payloads'
[[ ! -e "$XDG_CONFIG_HOME/firefox-floating-urlbar/profile" ]] || fail 'real remote uninstall left saved state'
[[ "$(cat "$TEST_DIR/real-profile/chrome/utils/boot.sys.mjs")" == 'existing external loader' ]] || fail 'real remote uninstall changed external loader'
[[ -z "$(find "$TEST_DIR/tmp" -mindepth 1)" ]] || fail 'real remote install/uninstall left temporary downloads'

# Execute the actual README paste command with success and failure from our stub.
paste_command="$(sed -n '/^installer=$(curl /{p;q;}' "$REPO_DIR/README.md")"
[[ -n "$paste_command" ]] || fail 'Bash installation command missing from README'
export TEST_INITIAL_TRACE="$TEST_DIR/initial.trace"
bash -c "$paste_command"
[[ "$(cat "$TEST_INITIAL_TRACE")" == 'downloaded installer ran' ]] || fail 'paste command did not execute the downloaded installer'
rm "$TEST_INITIAL_TRACE"
status=0
TEST_CURL_FAIL=7 bash -c "$paste_command" || status=$?
[[ "$status" == 7 ]] || fail 'paste command swallowed initial download failure'
[[ ! -e "$TEST_INITIAL_TRACE" ]] || fail 'paste command ran installer after download failure'

echo 'Remote installer regressions passed (fixture downloads and stubbed curl; no network).'

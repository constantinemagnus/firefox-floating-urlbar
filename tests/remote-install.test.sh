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
elif [[ "$url" == https://api.github.com/repos/constantinemagnus/firefox-floating-urlbar/commits/main ]]; then
    printf '%s\n' "${TEST_REVISION:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
else
    prefix='https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/'
    [[ "$url" == "$prefix"* ]] || exit 1
    file="${url#"$prefix"}"
    printf '%s\n' "$file" >> "$TEST_DOWNLOAD_TRACE"
    [[ "$file" != "${TEST_MISSING_FILE:-}" ]] || exit 22
    if [[ -f "$TEST_SOURCE/$file" ]]; then cp "$TEST_SOURCE/$file" "$output";
    elif [[ "${TEST_REAL_SOURCE:-0}" == 0 ]]; then printf 'fixture\n' > "$output";
    else exit 22; fi
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

# Default mode uses one immutable revision and fetches only installer inputs.
unset FIREFOX_FLOATING_URLBAR_URL
export TEST_SOURCE="$TEST_DIR/fixture/firefox-floating-urlbar-main"
export TEST_DOWNLOAD_TRACE="$TEST_DIR/download.trace"
bash "$REPO_DIR/install-remote.sh" --uninstall --profile '/temporary profile'
[[ "$(cat "$TEST_INSTALL_TRACE")" == "$(printf '%s\n' uninstall --profile '/temporary profile')" ]] || fail 'lean installer did not route arguments'
expected="$(printf '%s\n' install.sh uninstall.sh lib.sh autoconfig.sh fx-autoconfig.conf JS/replace-new-tab.uc.js CSS/firefox-floating-urlbar.uc.css)"
[[ "$(cat "$TEST_DOWNLOAD_TRACE")" == "$expected" ]] || fail 'lean installer downloaded unexpected files'
[[ -z "$(find "$TEST_DIR/tmp" -mindepth 1)" ]] || fail 'lean installer left temporary files'

for failure in download invalid-revision missing-file; do
    rm -f "$TEST_INSTALL_TRACE" "$TEST_DOWNLOAD_TRACE"
    status=0
    case "$failure" in
        download) TEST_CURL_FAIL=7 bash "$REPO_DIR/install-remote.sh" > "$TEST_DIR/failure.log" 2>&1 || status=$? ;;
        invalid-revision) TEST_REVISION='{"message":"API rate limit exceeded"}' bash "$REPO_DIR/install-remote.sh" > "$TEST_DIR/failure.log" 2>&1 || status=$? ;;
        missing-file) TEST_MISSING_FILE=fx-autoconfig.conf bash "$REPO_DIR/install-remote.sh" > "$TEST_DIR/failure.log" 2>&1 || status=$? ;;
    esac
    [[ "$status" != 0 ]] || fail "accepted $failure"
    [[ ! -e "$TEST_INSTALL_TRACE" ]] || fail "ran installer after $failure"
    [[ -z "$(find "$TEST_DIR/tmp" -mindepth 1)" ]] || fail "$failure left temporary files"
done

# Serve the checkout's real installers through the same immutable download path.
export TEST_SOURCE="$TEST_DIR/real-source" TEST_REAL_SOURCE=1
export XDG_CONFIG_HOME="$TEST_DIR/config"
mkdir -p "$TEST_SOURCE/JS" "$TEST_SOURCE/CSS" "$TEST_DIR/real-profile/chrome/utils" "$TEST_DIR/real-Firefox/defaults/pref"
cp "$REPO_DIR/"*.sh "$REPO_DIR/fx-autoconfig.conf" "$TEST_SOURCE/"
cp "$REPO_DIR/JS/replace-new-tab.uc.js" "$TEST_SOURCE/JS/"
cp "$REPO_DIR/CSS/firefox-floating-urlbar.uc.css" "$TEST_SOURCE/CSS/"
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

# The paste command must not run an empty shell when its initial curl fails.
status=0
TEST_CURL_FAIL=7 bash -c 'installer=$(curl -fsSL https://example.invalid/bootstrap) && bash -c "$installer"' || status=$?
[[ "$status" == 7 ]] || fail 'paste command swallowed initial download failure'

echo 'Remote installer regressions passed (fixture downloads and stubbed curl; no network).'
